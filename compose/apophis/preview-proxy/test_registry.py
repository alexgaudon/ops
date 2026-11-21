import base64
import tempfile
import unittest
from pathlib import Path

from registry import create_app


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.clock = 1000
        self.env = {
            "PREVIEW_DB": str(Path(self.dir.name) / "state.sqlite3"),
            "PREVIEW_INTERNAL_TARGETS": "10.0.0.49:3000-3999",
            "PREVIEW_EXTERNAL_TARGETS": "10.0.0.49:3000",
            "PREVIEW_INTERNAL_TOKEN": "i" * 32,
            "PREVIEW_EXTERNAL_TOKEN": "e" * 32,
        }
        self.api = create_app(self.env, now=lambda: self.clock).test_client()
        self.lookups = {scope: create_app({**self.env, "PREVIEW_ROLE": "lookup", "PREVIEW_LOOKUP_SCOPE": scope},
                                          now=lambda: self.clock).test_client()
                        for scope in ("internal", "external")}

    def create(self, key="i", **changes):
        body = {"name": "demo", "ip": "10.0.0.49", "port": 3000, "ttl_seconds": 60, **changes}
        return self.api.post("/v1/routes", json=body, headers={"Authorization": f"Bearer {key * 32}"})

    def resolve(self, scope="internal", **headers):
        domain = "dev" if scope == "internal" else "preview.external"
        return self.lookups[scope].get(f"/resolve/{scope}", headers={"X-Preview-Host": f"demo.{domain}.misery.systems", **headers})

    def test_create_expire_and_reuse(self):
        result = self.create()
        self.assertEqual(result.status_code, 201)
        self.assertEqual(result.json["url"], "https://demo.dev.misery.systems/")
        self.assertEqual(self.resolve().headers["X-Preview-Upstream"], "10.0.0.49:3000")
        self.assertEqual(self.create().status_code, 409)
        self.clock += 60
        self.assertEqual(self.resolve().status_code, 404)
        self.assertEqual(self.create().status_code, 201)

    def test_scope_and_destination_validation(self):
        self.assertEqual(self.create(scope="external").status_code, 401)
        self.assertEqual(self.create(key="e").status_code, 401)
        self.assertEqual(self.create(ip="10.0.0.50").status_code, 403)
        self.assertEqual(self.create(ip="127.0.0.1").status_code, 400)
        self.assertEqual(self.create(ip="demo.local").status_code, 400)
        self.assertEqual(self.create(port=True).status_code, 400)
        self.assertEqual(self.create(port=4000).status_code, 403)
        self.assertEqual(self.create(name="preview-api").status_code, 400)
        self.assertEqual(self.create(key="e", scope="external", port=3001).status_code, 403)

    def test_public_password_and_deletion(self):
        self.assertEqual(self.create().status_code, 201)
        self.assertEqual(self.lookups["external"].get("/resolve/internal", headers={
            "X-Preview-Host": "demo.dev.misery.systems"}).status_code, 404)
        self.assertEqual(self.resolve("external").status_code, 404)
        public = self.create(key="e", scope="external")
        self.assertEqual(public.status_code, 201)
        self.assertEqual(public.json["url"], "https://demo.preview.external.misery.systems/")
        self.assertEqual(self.resolve("external").status_code, 401)
        password = public.json["basic_auth"]["password"]
        authorization = "Basic " + base64.b64encode(f"preview:{password}".encode()).decode()
        self.assertEqual(self.resolve("external", Authorization=authorization).status_code, 204)
        path = "/v1/routes/external/demo"
        self.assertEqual(self.api.delete(path, headers={"Authorization": "Bearer " + "i" * 32}).status_code, 401)
        self.assertEqual(self.api.delete(path, headers={"Authorization": "Bearer " + "e" * 32}).status_code, 204)
        self.assertEqual(self.resolve("external").status_code, 404)
        self.assertEqual(self.resolve().status_code, 204)

    def test_week_long_expiry_is_external_only(self):
        self.assertEqual(self.create(ttl_seconds=86401).status_code, 400)
        self.assertEqual(self.create(key="e", scope="external", ttl_seconds=604801).status_code, 400)
        public = self.create(key="e", scope="external", ttl_seconds=604800)
        self.assertEqual(public.status_code, 201)
        self.assertEqual(public.json["expires_at"], self.clock + 604800)
        self.clock += 604799
        self.assertEqual(self.resolve("external").status_code, 401)
        self.clock += 1
        self.assertEqual(self.resolve("external").status_code, 404)

    def test_password_exception_matches_only_the_original_route(self):
        env = {**self.env, "PREVIEW_PUBLIC_WITHOUT_LOGIN": "demo=10.0.0.49:3000:1060"}
        api = create_app(env, now=lambda: self.clock).test_client()
        self.lookups["external"] = create_app({**env, "PREVIEW_ROLE": "lookup", "PREVIEW_LOOKUP_SCOPE": "external"},
                                              now=lambda: self.clock).test_client()
        self.assertEqual(self.create(key="e", scope="external").status_code, 201)
        self.assertEqual(self.create(key="e", scope="external", name="other").status_code, 201)
        self.assertEqual(self.resolve("external").status_code, 204)
        other = self.lookups["external"].get("/resolve/external", headers={
            "X-Preview-Host": "other.preview.external.misery.systems"})
        self.assertEqual(other.status_code, 401)
        route = api.get("/v1/routes?scope=external").json["routes"][0]
        self.assertFalse(route["login_required"])
        self.assertIsNone(route["basic_auth"])
        self.assertIn(b"No login required.", api.get("/?scope=external").data)
        self.clock += 60
        self.assertEqual(self.resolve("external").status_code, 404)
        self.assertEqual(self.create(key="e", scope="external").status_code, 201)
        self.assertEqual(self.resolve("external").status_code, 401)

    def test_pinned_internal_route_does_not_expire(self):
        env = {**self.env, "PREVIEW_PINNED_INTERNAL": "demo=10.0.0.49:3000"}
        self.api = create_app(env, now=lambda: self.clock).test_client()
        self.lookups["internal"] = create_app({**env, "PREVIEW_ROLE": "lookup",
                                               "PREVIEW_LOOKUP_SCOPE": "internal"},
                                              now=lambda: self.clock).test_client()
        self.assertEqual(self.create().status_code, 409)
        auth = {"Authorization": "Bearer " + "i" * 32}
        self.assertEqual(self.api.delete("/v1/routes/internal/demo", headers=auth).status_code, 409)
        self.clock += 86401
        self.assertEqual(self.resolve().headers["X-Preview-Upstream"], "10.0.0.49:3000")
        self.assertIsNone(self.api.get("/v1/routes").json["routes"][0]["expires_at"])
        self.assertIn(b"Never (pinned)", self.api.get("/").data)
        self.assertEqual(self.resolve("external").status_code, 404)

    def test_list_routes_is_read_only_and_uncached(self):
        self.assertEqual(self.api.get("/v1/routes").json, {"scope": "all", "routes": []})
        empty = self.api.get("/")
        self.assertEqual(empty.mimetype, "text/html")
        self.assertIn(b"No active previews", empty.data)
        self.assertEqual(self.api.get("/v1/routes?scope=invalid").status_code, 400)
        self.assertEqual(self.api.post("/v1/routes", json={}).status_code, 401)
        self.assertEqual(self.api.delete("/v1/routes/internal/lan-only").status_code, 401)
        self.assertEqual(self.create(name="lan-only").status_code, 201)
        public = self.create(key="e", scope="external").json
        all_routes = self.api.get("/v1/routes").json["routes"]
        self.assertEqual({r["scope"] for r in all_routes}, {"internal", "external"})
        self.assertEqual([r["name"] for r in self.api.get("/v1/routes?scope=internal").json["routes"]], ["lan-only"])
        page = self.api.get("/?scope=external")
        self.assertIn(b"Show login", page.data)
        self.assertIn(public["basic_auth"]["password"].encode(), page.data)
        login_url = public["url"].replace("https://", f"https://preview:{public['basic_auth']['password']}@", 1)
        self.assertIn(f"<code>{login_url}</code>".encode(), page.data)
        self.assertNotIn(f'href="{login_url}"'.encode(), page.data)
        self.assertNotIn(b"Login URL", self.api.get("/?scope=internal").data)
        self.assertIn(b'<button class="copy-login" type="button" hidden>Copy login URL</button>', page.data)
        self.assertIn(b'role="status"', page.data)
        self.assertNotIn(b"lan-only", page.data)
        self.assertIn("frame-ancestors 'none'", page.headers["Content-Security-Policy"])
        nonce = page.data.split(b'<script nonce="', 1)[1].split(b'"', 1)[0].decode()
        self.assertIn(f"script-src 'nonce-{nonce}'", page.headers["Content-Security-Policy"])
        response = self.api.get("/v1/routes?scope=external")
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertEqual(response.headers["Cross-Origin-Resource-Policy"], "same-origin")
        self.assertEqual([r["basic_auth"] for r in response.json["routes"]], [public["basic_auth"]])
        self.assertEqual(self.lookups["external"].get("/v1/routes").status_code, 404)
        self.clock += 60
        self.assertEqual(self.api.get("/v1/routes").json["routes"], [])
        replacement = self.create(key="e", scope="external").json
        self.assertNotEqual(replacement["basic_auth"], public["basic_auth"])


if __name__ == "__main__":
    unittest.main()
