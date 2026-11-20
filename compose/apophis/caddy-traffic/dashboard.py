"""Read-only, aggregate view of the two Caddy access logs."""

from collections import Counter
from datetime import datetime, timezone
from gzip import open as gzip_open
from html import escape
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import re
import time
from urllib.parse import urlsplit


WINDOWS = {"/": 3600, "/day": 86400}
LOG_ROOTS = {"Public": Path("/logs/public"), "Internal": Path("/logs/internal")}
HOST = re.compile(r"[a-z0-9.-]{1,100}(?::[0-9]{1,5})?", re.ASCII)
SEGMENT = re.compile(r"[a-zA-Z0-9_.~-]{1,36}", re.ASCII)
IDENTIFIER = re.compile(r"\d+|[a-f0-9-]{16,}|[A-Za-z0-9_-]{24,}", re.I)
METHODS = {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"}
CSS = Path(__file__).with_name("dashboard.css").read_bytes()


def endpoint(uri):
    path = uri.split("?", 1)[0]
    if not path.startswith("/"):
        return "/…"
    if re.search(r"\.(css|js|mjs|svg|woff2?|ico|png|jpe?g|webp|map)$", path, re.I):
        return "(static assets)"
    segments = path.strip("/").split("/")
    cleaned = [part if SEGMENT.fullmatch(part) and not IDENTIFIER.fullmatch(part)
               else ":id" for part in segments[:8] if part]
    return "/" + "/".join(cleaned + (["…"] if len(segments) > 8 else []))


def bounded_add(counter, key, other):
    counter[key if key in counter or len(counter) < 4096 else other] += 1


def summarize(roots, now):
    stats = {period: {"hosts": Counter(), "endpoints": Counter(), "status": Counter(),
                      "total": 0, "bytes": 0, "first": None} for period in WINDOWS.values()}
    gaps = set()
    for listener, directory in roots.items():
        seen = set()
        current = directory / "access.log"
        if not current.is_file():
            gaps.add(listener)
        # Caddy's size/time rotation can briefly leave a name missing. Check
        # inode identity to avoid counting a rotated file twice in one scan.
        for path in [current, *sorted(directory.glob("access-*.log*"), reverse=True)]:
            try:
                st = path.stat()
                if st.st_mtime < now - 86400 or (st.st_dev, st.st_ino) in seen:
                    continue
                opener = gzip_open if path.suffix == ".gz" else open
                with opener(path, "rb") as stream:
                    seen.add((st.st_dev, st.st_ino))
                    for line in stream:
                        try:
                            row = json.loads(line)
                            ts, status, req = float(row["ts"]), int(row["status"]), row["request"]
                            if not now - 86400 <= ts <= now or not 100 <= status <= 599:
                                continue
                            host = req["host"].lower()
                            host = host if HOST.fullmatch(host) else "(other host)"
                            path_group = endpoint(req["uri"])
                            method = req["method"] if req["method"] in METHODS else "OTHER"
                            size = max(0, int(row.get("size", 0)))
                        except (ValueError, TypeError, KeyError, AttributeError, OverflowError):
                            continue
                        for period, window in stats.items():
                            if ts < now - period:
                                continue
                            window["total"] += 1
                            window["bytes"] += size
                            window["status"][status] += 1
                            window["first"] = min(window["first"] or ts, ts)
                            bounded_add(window["hosts"], (listener, host), (listener, "(other hosts)"))
                            bounded_add(window["endpoints"], (listener, host, method, path_group),
                                        (listener, "(other hosts)", "OTHER", "(other endpoints)"))
            except (OSError, EOFError):
                # A file can be compressed or replaced during rotation.
                gaps.add(listener)
    return stats, gaps


def size_label(size):
    if size < 1024:
        return f"{size:,} B"
    if size < 1024**2:
        return f"{size / 1024:,.1f} KiB"
    if size < 1024**3:
        return f"{size / 1024**2:,.1f} MiB"
    return f"{size / 1024**3:,.2f} GiB"


def row_host(key, count, peak):
    listener, host = key
    return (f'<tr><td><code>{escape(host)}</code><br><small>{listener}</small></td>'
            f'<td class="n"><meter aria-label="Relative request volume" min="0" '
            f'max="{peak}" value="{count}"></meter> {count:,}</td></tr>')


def row_endpoint(key, count):
    listener, host, method, path = key
    return (f'<tr><td><code>{escape(method)} {escape(path)}</code><br>'
            f'<small>{escape(host)} · {listener}</small></td><td class="n">{count:,}</td></tr>')


def render(route, window, gaps, now):
    hosts = window["hosts"].most_common(15)
    endpoints = window["endpoints"].most_common(20)
    empty = '<tr><td colspan="2">No requests recorded for this window.</td></tr>'
    host_rows = "".join(row_host(k, v, hosts[0][1]) for k, v in hosts) or empty
    endpoint_rows = "".join(row_endpoint(k, v) for k, v in endpoints) or empty
    current = ' aria-current="page"'
    nav = (f'<a href="/"{current if route == "/" else ""}>Last hour</a>'
           f'<a href="/day"{current if route == "/day" else ""}>Last 24 hours</a>')
    stamp = datetime.fromtimestamp(now, timezone.utc).strftime("%H:%M:%S UTC")
    first = window["first"]
    first_label = (datetime.fromtimestamp(first, timezone.utc).strftime("%b %d, %H:%M UTC")
                   if first is not None else "none in this window")
    errors = [sum(n for code, n in window["status"].items() if code // 100 == group)
              for group in (4, 5)]
    warning = (f'<p class="warn">Some {", ".join(sorted(gaps)).lower()} logs '
               'could not be read; counts may be incomplete.</p>' if gaps else "")
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Caddy traffic</title><link rel="stylesheet" href="/dashboard.css"></head>
<body><main><header><div><h1>Caddy traffic</h1><p class="note">Public and internal · Snapshot at {stamp}</p></div>
<nav aria-label="Time window">{nav}</nav></header>
<dl class="totals"><div><dt>Requests</dt><dd>{window['total']:,}</dd></div><div><dt>Response bytes</dt><dd>{size_label(window['bytes'])}</dd></div>
<div><dt>4xx responses</dt><dd>{errors[0]:,}</dd></div><div><dt>5xx responses</dt><dd class="{'error' if errors[1] else ''}">{errors[1]:,}</dd></div></dl>
{warning}<div class="ledgers"><section aria-labelledby="hosts"><h2 id="hosts">Top hosts</h2>
<table aria-labelledby="hosts"><thead><tr><th scope="col">Host / listener</th><th scope="col" class="n">Requests</th></tr></thead><tbody>{host_rows}</tbody></table></section>
<section aria-labelledby="endpoints"><h2 id="endpoints">Top endpoints</h2>
<table aria-labelledby="endpoints"><thead><tr><th scope="col">Method / path</th><th scope="col" class="n">Requests</th></tr></thead><tbody>{endpoint_rows}</tbody></table></section></div>
<footer>First recorded request: {first_label}. Query strings are omitted, common IDs and static assets are grouped.
Reload to update; snapshots are cached for up to 30 seconds.</footer></main></body></html>'''.encode()


class Handler(BaseHTTPRequestHandler):
    cache = None

    def log_message(self, *_args):
        pass

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        try:
            route = urlsplit(self.path).path
        except ValueError:
            route = ""
        if route == "/dashboard.css":
            return self.send_content(200, "text/css", CSS)
        if route not in WINDOWS:
            return self.send_content(404, "text/plain", b"Not found\n")
        now = time.time()
        if not Handler.cache or time.monotonic() >= Handler.cache[0]:
            stats, gaps = summarize(LOG_ROOTS, now)
            pages = {path: render(path, stats[period], gaps, now) for path, period in WINDOWS.items()}
            Handler.cache = time.monotonic() + 30, pages
        self.send_content(200, "text/html", Handler.cache[1][route])

    def send_content(self, status, content_type, body):
        self.send_response(status)
        self.send_header("Content-Type", content_type + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class DashboardServer(HTTPServer):
    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        return connection, address


if __name__ == "__main__":
    DashboardServer(("0.0.0.0", 8080), Handler).serve_forever()
