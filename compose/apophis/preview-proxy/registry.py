import base64
import hashlib
import hmac
import ipaddress
import os
import re
import secrets
import sqlite3
import time
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path

from flask import Flask, Response, jsonify, render_template, request


DOMAINS = {"internal": "dev.misery.systems", "external": "preview.external.misery.systems"}
NAME = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", re.ASCII)
TOKEN = re.compile(r"[A-Za-z0-9_-]{32,128}", re.ASCII)
LAN = tuple(map(ipaddress.IPv4Network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))


def private_ip(value):
    if not isinstance(value, str):
        raise ValueError("expected a private IPv4 address")
    ip = ipaddress.IPv4Address(value)
    if not any(ip in net for net in LAN):
        raise ValueError("expected an RFC1918 IPv4 address")
    return str(ip)


def target_policy(value):
    rules = []
    for entry in filter(None, map(str.strip, value.split(","))):
        ip, bounds = entry.split(":", 1)
        start, _, end = bounds.partition("-")
        low, high = int(start), int(end or start)
        if not 1024 <= low <= high <= 65535:
            raise ValueError("target policy ports must be between 1024 and 65535")
        rules.append((private_ip(ip), low, high))
    return rules


def digest(value):
    return hashlib.sha256(value.encode("ascii")).hexdigest()


def create_app(config=os.environ, *, now=time.time):
    app = Flask(__name__, static_folder=None)
    app.config.update(MAX_CONTENT_LENGTH=4096, MAX_FORM_MEMORY_SIZE=4096)
    role = config.get("PREVIEW_ROLE", "api")
    if role not in {"api", "lookup"}:
        raise ValueError("unknown preview service role")
    db = Path(config.get("PREVIEW_DB", "/state/routes.sqlite3")).absolute()
    policy = {scope: target_policy(config.get(f"PREVIEW_{scope.upper()}_TARGETS", ""))
              for scope in DOMAINS}
    lookup_scope = config.get("PREVIEW_LOOKUP_SCOPE")
    if role == "lookup" and lookup_scope not in DOMAINS:
        raise ValueError("configure the lookup scope")
    tokens = {scope: config.get(f"PREVIEW_{scope.upper()}_TOKEN", "") for scope in DOMAINS}

    def connect(*, readonly=False):
        mode = "ro" if readonly else "rwc"
        return sqlite3.connect(f"{db.as_uri()}?mode={mode}", uri=True, timeout=2)

    def allowed(scope, ip, port):
        return any(ip == target and low <= port <= high for target, low, high in policy[scope])

    # Match the existing route's full identity, including its original expiry.
    public_without_login = config.get("PREVIEW_PUBLIC_WITHOUT_LOGIN", "")

    def no_login(name, ip, port, expires):
        return public_without_login == f"{name}={ip}:{port}:{expires}"

    pinned = {}
    for entry in filter(None, map(str.strip, config.get("PREVIEW_PINNED_INTERNAL", "").split(","))):
        name, target = entry.split("=", 1)
        ip, port = target.rsplit(":", 1)
        ip, port = private_ip(ip), int(port)
        if not NAME.fullmatch(name) or name == "preview-api" or name in pinned or not allowed("internal", ip, port):
            raise ValueError("invalid pinned internal preview")
        pinned[name] = (ip, port)

    def reserved_name(scope, name):
        return scope == "internal" and name == "preview-api"

    # Auth and lookup responses must not be reused across requests or users.
    @app.after_request
    def disable_cache(response):
        response.headers["Cache-Control"] = "no-store"
        response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    if role == "api":
        if (not TOKEN.fullmatch(tokens["internal"])
                or (tokens["external"] and not TOKEN.fullmatch(tokens["external"]))
                or tokens["internal"] == tokens["external"]):
            raise ValueError("set distinct random API tokens (32+ URL-safe characters)")
        with closing(connect()) as conn, conn:
            conn.execute("""CREATE TABLE IF NOT EXISTS routes (
                scope TEXT NOT NULL, name TEXT NOT NULL, ip TEXT NOT NULL,
                port INTEGER NOT NULL, expires INTEGER NOT NULL, password TEXT,
                PRIMARY KEY (scope, name))""")
            conn.execute("""CREATE TABLE IF NOT EXISTS external_nonces (
                name TEXT PRIMARY KEY, nonce TEXT NOT NULL)""")

        def authorized(scope):
            value = request.headers.get("Authorization", "").removeprefix("Bearer ")
            token = tokens.get(scope)
            return bool(token and TOKEN.fullmatch(value) and hmac.compare_digest(token, value)
                        and request.headers.get("Authorization", "").startswith("Bearer "))

        def external_password(name, nonce):
            message = f"preview-password-v1:{name}:{nonce}".encode("ascii")
            return hmac.digest(tokens["external"].encode("ascii"), message, "sha256").hex()

        @app.get("/")
        @app.get("/v1/routes")
        def list_routes():
            scope = request.args.get("scope")
            if scope is not None and scope not in DOMAINS:
                return jsonify(error="invalid scope"), 400
            # Only internal Caddy can reach this service. Its LAN policy gates reads;
            # write operations still require the appropriate scope token.
            with closing(connect(readonly=True)) as conn:
                rows = conn.execute("""SELECT r.scope, r.name, r.ip, r.port, r.expires, r.password, n.nonce
                    FROM routes AS r LEFT JOIN external_nonces AS n ON r.scope = 'external' AND r.name = n.name
                    WHERE (? IS NULL OR r.scope = ?) AND r.expires > ?
                    ORDER BY r.scope, r.name""", (scope, scope, int(now()))).fetchall()
            routes = []
            if scope in (None, "internal"):
                routes.extend({"scope": "internal", "name": name, "ip": ip, "port": port,
                               "expires_at": None, "url": f"https://{name}.{DOMAINS['internal']}/"}
                              for name, (ip, port) in sorted(pinned.items()))
            for route_scope, name, ip, port, expires, password_hash, nonce in rows:
                if (route_scope == "internal" and name in pinned) or not allowed(route_scope, ip, port):
                    continue
                route = {"scope": route_scope, "name": name, "ip": ip, "port": port, "expires_at": expires,
                         "url": f"https://{name}.{DOMAINS[route_scope]}/"}
                if route_scope == "external":
                    route["login_required"] = not no_login(name, ip, port, expires)
                    password = external_password(name, nonce) if nonce and route["login_required"] else None
                    if password and hmac.compare_digest(digest(password), password_hash or ""):
                        route["basic_auth"] = {"username": "preview", "password": password}
                    else:
                        route["basic_auth"] = None
                routes.append(route)
            if request.path == "/":
                for route in routes:
                    if route["expires_at"] is None:
                        continue
                    expires = datetime.fromtimestamp(route["expires_at"], timezone.utc)
                    route.update(expires_iso=expires.isoformat(), expires_label=expires.strftime("%Y-%m-%d %H:%M UTC"))
                nonce = secrets.token_urlsafe(18)
                return Response(render_template("previews.html", routes=routes, scope=scope, nonce=nonce),
                                mimetype="text/html", headers={
                                     "Content-Security-Policy": f"default-src 'none'; style-src 'self' 'nonce-{nonce}'; script-src 'nonce-{nonce}'; frame-ancestors 'none'; base-uri 'none'",
                                    "Referrer-Policy": "no-referrer",
                                })
            return jsonify(scope=scope or "all", routes=routes)

        @app.post("/v1/routes")
        def create():
            body = request.get_json(silent=True)
            if not isinstance(body, dict) or body.keys() - {"name", "ip", "port", "scope", "ttl_seconds"}:
                return jsonify(error="expected a route JSON object"), 400
            scope = body.get("scope", "internal")
            if not isinstance(scope, str) or scope not in DOMAINS:
                return jsonify(error="invalid scope"), 400
            if not authorized(scope):
                return jsonify(error="unauthorized"), 401
            name, port = body.get("name"), body.get("port")
            ttl = body.get("ttl_seconds", 3600)
            if not isinstance(name, str) or not NAME.fullmatch(name) or reserved_name(scope, name):
                return jsonify(error="invalid or reserved name"), 400
            if scope == "internal" and name in pinned:
                return jsonify(error="preview is managed by server configuration"), 409
            max_ttl = 604800 if scope == "external" else 86400
            if type(port) is not int or type(ttl) is not int or not 60 <= ttl <= max_ttl:
                return jsonify(error=f"invalid port or TTL (60–{max_ttl} seconds)"), 400
            try:
                ip = private_ip(body.get("ip"))
            except ValueError:
                return jsonify(error="expected a private IPv4 address"), 400
            if not allowed(scope, ip, port):
                return jsonify(error="target is not permitted for this scope"), 403
            nonce = secrets.token_hex(16) if scope == "external" else None
            password = external_password(name, nonce) if nonce else None
            expires = int(now()) + ttl
            with closing(connect()) as conn, conn:
                conn.execute("DELETE FROM routes WHERE expires <= ?", (int(now()),))
                conn.execute("""DELETE FROM external_nonces WHERE name NOT IN
                    (SELECT name FROM routes WHERE scope = 'external')""")
                if conn.execute("SELECT count(*) FROM routes WHERE scope = ?", (scope,)).fetchone()[0] >= 100:
                    return jsonify(error="route limit reached"), 409
                cursor = conn.execute("INSERT OR IGNORE INTO routes VALUES (?, ?, ?, ?, ?, ?)",
                                      (scope, name, ip, port, expires, digest(password) if password else None))
                if cursor.rowcount != 1:
                    return jsonify(error="name already registered"), 409
                if nonce:
                    conn.execute("INSERT OR REPLACE INTO external_nonces VALUES (?, ?)", (name, nonce))
            result = {"url": f"https://{name}.{DOMAINS[scope]}/", "expires_at": expires}
            if password:
                result["basic_auth"] = {"username": "preview", "password": password}
            return jsonify(result), 201

        @app.delete("/v1/routes/<scope>/<name>")
        def delete(scope, name):
            if not authorized(scope):
                return jsonify(error="unauthorized"), 401
            if scope == "internal" and name in pinned:
                return jsonify(error="preview is managed by server configuration"), 409
            with closing(connect()) as conn, conn:
                conn.execute("DELETE FROM routes WHERE scope = ? AND name = ?", (scope, name))
                if scope == "external":
                    conn.execute("DELETE FROM external_nonces WHERE name = ?", (name,))
            return Response(status=204)

    else:
        @app.get("/resolve/<scope>")
        def resolve(scope):
            host = request.headers.get("X-Preview-Host", "").lower()
            name, _, domain = host.partition(".")
            if (scope != lookup_scope or domain != DOMAINS[scope] or not NAME.fullmatch(name)
                    or reserved_name(scope, name)):
                return Response(status=404)
            if scope == "internal" and name in pinned:
                ip, port = pinned[name]
                return Response(status=204, headers={"X-Preview-Upstream": f"{ip}:{port}"})
            with closing(connect(readonly=True)) as conn:
                row = conn.execute("SELECT ip, port, password, expires FROM routes WHERE scope = ? AND name = ? AND expires > ?",
                                   (scope, name, int(now()))).fetchone()
            if row is None or not allowed(scope, row[0], row[1]):
                return Response(status=404)
            ip, port, password, expires = row
            if scope == "external" and not no_login(name, ip, port, expires):
                scheme, _, encoded = request.headers.get("Authorization", "").partition(" ")
                try:
                    raw = base64.b64decode(encoded, validate=True).decode("ascii") if len(encoded) <= 100 else ""
                    username, _, supplied = raw.partition(":")
                    valid = (scheme.lower() == "basic" and username == "preview" and bool(password)
                             and hmac.compare_digest(digest(supplied), password))
                except ValueError:
                    valid = False
                if not valid:
                    return Response(status=401, headers={"WWW-Authenticate": 'Basic realm="Preview"'})
            return Response(status=204, headers={"X-Preview-Upstream": f"{ip}:{port}"})

    return app


# Gunicorn calls the factory so tests can inject a temporary store and clock.
