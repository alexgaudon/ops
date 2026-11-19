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
from pathlib import Path

from flask import Flask, Response, jsonify, request


DOMAINS = {"internal": "dev.misery.systems", "external": "external.misery.systems"}
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
    reserved = set(filter(None, (n.strip() for n in config.get("PREVIEW_RESERVED_EXTERNAL", "").split(","))))
    if not all(NAME.fullmatch(name) for name in reserved):
        raise ValueError("invalid reserved preview name")
    tokens = {scope: config.get(f"PREVIEW_{scope.upper()}_TOKEN", "") for scope in DOMAINS}

    def connect(*, readonly=False):
        mode = "ro" if readonly else "rwc"
        return sqlite3.connect(f"{db.as_uri()}?mode={mode}", uri=True, timeout=2)

    def allowed(scope, ip, port):
        return any(ip == target and low <= port <= high for target, low, high in policy[scope])

    def reserved_name(scope, name):
        return (scope == "internal" and name == "preview-api") or (scope == "external" and name in reserved)

    # Auth and lookup responses must not be reused across requests or users.
    @app.after_request
    def disable_cache(response):
        response.headers["Cache-Control"] = "no-store"
        return response

    if role == "api":
        if (not TOKEN.fullmatch(tokens["internal"])
                or (tokens["external"] and not TOKEN.fullmatch(tokens["external"]))
                or tokens["internal"] == tokens["external"]):
            raise ValueError("set distinct random API tokens (32+ URL-safe characters)")
        if tokens["external"] and not reserved:
            raise ValueError("configure the reserved external hostnames before enabling publishing")
        with closing(connect()) as conn, conn:
            conn.execute("""CREATE TABLE IF NOT EXISTS routes (
                scope TEXT NOT NULL, name TEXT NOT NULL, ip TEXT NOT NULL,
                port INTEGER NOT NULL, expires INTEGER NOT NULL, password TEXT,
                PRIMARY KEY (scope, name))""")

        def authorized(scope):
            value = request.headers.get("Authorization", "").removeprefix("Bearer ")
            token = tokens.get(scope)
            return bool(token and TOKEN.fullmatch(value) and hmac.compare_digest(token, value)
                        and request.headers.get("Authorization", "").startswith("Bearer "))

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
            if type(port) is not int or type(ttl) is not int or not 60 <= ttl <= 86400:
                return jsonify(error="invalid port or TTL (60–86400 seconds)"), 400
            try:
                ip = private_ip(body.get("ip"))
            except ValueError:
                return jsonify(error="expected a private IPv4 address"), 400
            if not allowed(scope, ip, port):
                return jsonify(error="target is not permitted for this scope"), 403
            password = secrets.token_urlsafe(24) if scope == "external" else None
            expires = int(now()) + ttl
            with closing(connect()) as conn, conn:
                conn.execute("DELETE FROM routes WHERE expires <= ?", (int(now()),))
                if conn.execute("SELECT count(*) FROM routes WHERE scope = ?", (scope,)).fetchone()[0] >= 100:
                    return jsonify(error="route limit reached"), 409
                cursor = conn.execute("INSERT OR IGNORE INTO routes VALUES (?, ?, ?, ?, ?, ?)",
                                      (scope, name, ip, port, expires, digest(password) if password else None))
                if cursor.rowcount != 1:
                    return jsonify(error="name already registered"), 409
            result = {"url": f"https://{name}.{DOMAINS[scope]}/", "expires_at": expires}
            if password:
                result["basic_auth"] = {"username": "preview", "password": password}
            return jsonify(result), 201

        @app.delete("/v1/routes/<scope>/<name>")
        def delete(scope, name):
            if not authorized(scope):
                return jsonify(error="unauthorized"), 401
            with closing(connect()) as conn, conn:
                conn.execute("DELETE FROM routes WHERE scope = ? AND name = ?", (scope, name))
            return Response(status=204)

    else:
        @app.get("/resolve/<scope>")
        def resolve(scope):
            host = request.headers.get("X-Preview-Host", "").lower()
            name, _, domain = host.partition(".")
            if (scope not in DOMAINS or domain != DOMAINS[scope] or not NAME.fullmatch(name)
                    or reserved_name(scope, name)):
                return Response(status=404)
            with closing(connect(readonly=True)) as conn:
                row = conn.execute("SELECT ip, port, password FROM routes WHERE scope = ? AND name = ? AND expires > ?",
                                   (scope, name, int(now()))).fetchone()
            if row is None or not allowed(scope, row[0], row[1]):
                return Response(status=404)
            ip, port, password = row
            if scope == "external":
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
