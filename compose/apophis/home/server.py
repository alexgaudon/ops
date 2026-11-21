from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from math import isfinite
from pathlib import Path
from threading import Lock
from time import monotonic, perf_counter
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from media import media_widgets, poster

SITE = Path(__file__).with_name('site')
CHECKS = (
    ('Caddy Traffic', 'traffic.internal.misery.systems', 'http://caddy-traffic:8080/', 'Backend'),
    ('Jellyfin', 'jellyfin.misery.systems', 'https://jellyfin.misery.systems/System/Info/Public', 'HTTPS route'),
    ('Lootsheet', 'lootsheet.app', 'https://lootsheet.app/', 'HTTPS route'),
    ('Relay', 'relay.internal.misery.systems', 'http://10.0.0.32:8083/', 'Backend'),
    ('Tallyo', 'tallyo.internal.misery.systems', 'http://10.0.0.50:13880/api/auth/session', 'Backend'),
    ('Sonarr', 'sonarr.internal.misery.systems', 'http://10.0.0.5:8989/', 'Backend'),
    ('Radarr', 'radarr.internal.misery.systems', 'http://10.0.0.5:7878/', 'Backend'),
)
FORECAST = ('https://api.open-meteo.com/v1/forecast?latitude=47.56&longitude=-52.71'
            '&current=temperature_2m,apparent_temperature,weather_code'
            '&hourly=temperature_2m&forecast_days=2&timezone=America%2FSt_Johns')
LOCK = Lock()
WEATHER_LOCK = Lock()
snapshot = None
weather_snapshot = None


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def probe(check):
    name, host, url, target = check
    start = perf_counter()
    try:
        request = Request(url, headers={'Host': host})
        with build_opener(ProxyHandler({}), NoRedirect).open(request, timeout=3) as response:
            code = str(response.status)
    except HTTPError as error:
        code = str(error.code)
        error.close()
    except (OSError, URLError):
        return name, host, f'{target} · Unreachable', None, False
    ok = code == '200' or (name in ('Sonarr', 'Radarr') and code == '302')
    return name, host, f'{target} · HTTP {code}', round((perf_counter() - start) * 1000), ok


def weather_markup(data):
    current, hourly = data['current'], data['hourly']
    code = int(current['weather_code'])
    conditions = {0: 'Clear', 1: 'Mostly clear', 2: 'Partly cloudy', 3: 'Overcast',
                  45: 'Fog', 48: 'Freezing fog'}
    label = conditions.get(code, 'Drizzle' if 51 <= code <= 57 else
                           'Rain' if 61 <= code <= 67 or 80 <= code <= 82 else
                           'Snow' if 71 <= code <= 77 or 85 <= code <= 86 else
                           'Thunderstorms' if 95 <= code <= 99 else 'Conditions unavailable')
    samples = [(datetime.fromisoformat(t), float(temp))
               for t, temp in zip(hourly['time'], hourly['temperature_2m'])
               if t >= current['time'] and temp is not None][:18:3]
    temperature, feels = float(current['temperature_2m']), float(current['apparent_temperature'])
    if not all(isfinite(v) for v in (temperature, feels, *(v for _, v in samples))):
        raise ValueError('Non-finite weather values')
    lo = min((v for _, v in samples), default=0)
    hi = max((v for _, v in samples), default=0)
    hours = ''.join(f'<li><span>{v:.0f}°</span><meter min="0" max="1" '
                    f'value="{(v-lo)/(hi-lo):.2f}" aria-hidden="true"></meter>'
                    f'<time>{t:%H:%M}</time></li>' if hi > lo else
                    f'<li><span>{v:.0f}°</span><meter min="0" max="1" value="0.5" '
                    f'aria-hidden="true"></meter><time>{t:%H:%M}</time></li>' for t, v in samples)
    chart = f'<ul class="forecast" aria-label="Hourly forecast, local time">{hours}</ul>' if hours else ''
    return (f'<div class="weather-now"><strong>{temperature:.0f}°C</strong><div>{label}'
            f'<small>Feels like {feels:.0f}°C</small></div></div>{chart}')


def weather_html():
    global weather_snapshot
    with WEATHER_LOCK:
        if weather_snapshot is None or monotonic() >= weather_snapshot[0]:
            try:
                with build_opener(ProxyHandler({}), NoRedirect).open(FORECAST, timeout=3) as response:
                    markup = weather_markup(json.loads(response.read(48 * 1024)))
                ttl = 600
            except (OSError, ValueError, AttributeError, KeyError, TypeError):
                markup, ttl = '<p class="muted">Weather temporarily unavailable.</p>', 60
            weather_snapshot = monotonic() + ttl, markup
        return weather_snapshot[1]


def checks_html():
    global snapshot
    with LOCK:
        if snapshot is None or monotonic() >= snapshot[0]:
            with ThreadPoolExecutor(max_workers=len(CHECKS)) as pool:
                rows = list(pool.map(probe, CHECKS))
            stamp = datetime.now(timezone.utc).strftime('%H:%M:%S UTC')
            snapshot = monotonic() + 60, stamp, rows
        _, stamp, rows = snapshot
    body = []
    for name, host, detail, ms, ok in rows:
        state = 'Reachable' if ok else 'Check failed'
        latency = f'{ms:,} ms' if ms is not None else '—'
        body.append(f'<tr><th scope="row"><a href="https://{escape(host)}/">{escape(name)}</a></th>'
                    f'<td><span class="{"ok" if ok else "fail"}">{state}</span>'
                    f'<small>{escape(detail)}</small></td><td class="timing">{latency}</td></tr>')
    return stamp, ''.join(body)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        path = self.path.partition('?')[0]
        status = 200
        cache = 'no-store'
        if path == '/':
            with ThreadPoolExecutor(max_workers=3) as pool:
                forecast = pool.submit(weather_html)
                media_data = pool.submit(media_widgets)
                stamp, rows = checks_html()
            html = ((SITE / 'index.html').read_text().replace('<!-- CHECK_TIME -->', stamp)
                    .replace('<!-- CHECK_ROWS -->', rows).replace('<!-- WEATHER -->', forecast.result()))
            for name, value in media_data.result().items():
                html = html.replace(f'<!-- {name} -->', value)
            body = html.encode()
            media = 'text/html'
        elif path == '/home.css':
            body, media = (SITE / 'home.css').read_bytes(), 'text/css'
        elif path == '/home.js':
            body, media = (SITE / 'home.js').read_bytes(), 'text/javascript'
        elif path.startswith('/media/posters/') and (image := poster(path.removeprefix('/media/posters/'))) is not None:
            body, media = image, 'image/jpeg'
            cache = 'private, max-age=3600'
        else:
            status, body, media = 404, b'Not found\n', 'text/plain'
        self.send_response(status)
        self.send_header('Content-Type', media if media == 'image/jpeg' else f'{media}; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', cache)
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'self'; script-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)


if __name__ == '__main__':
    ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
