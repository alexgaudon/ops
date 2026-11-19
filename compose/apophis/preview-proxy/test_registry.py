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
            "PREVIEW_RESERVED_EXTERNAL": "static-app",
        }
        self.api = create_app(self.env, now=lambda: self.clock).test_client()
        self.lookup = create_app({**self.env, "PREVIEW_ROLE": "lookup"}, now=lambda: self.clock).test_client()

    def create(self, key="i", **changes):
        body = {"name": "demo", "ip": "10.0.0.49", "port": 3000, "ttl_seconds": 60, **changes}
        return self.api.post("/v1/routes", json=body, headers={"Authorization": f"Bearer {key * 32}"})

    def resolve(self, scope="internal", **headers):
        domain = "dev" if scope == "internal" else "external"
        return self.lookup.get(f"/resolve/{scope}", headers={"X-Preview-Host": f"demo.{domain}.misery.systems", **headers})

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
        self.assertEqual(self.create(key="e", scope="external", name="static-app").status_code, 400)
        self.assertEqual(self.create(key="e", scope="external", port=3001).status_code, 403)

    def test_public_password_and_deletion(self):
        self.assertEqual(self.create().status_code, 201)
        self.assertEqual(self.resolve("external").status_code, 404)
        public = self.create(key="e", scope="external")
        self.assertEqual(public.status_code, 201)
        self.assertEqual(self.resolve("external").status_code, 401)
        password = public.json["basic_auth"]["password"]
        authorization = "Basic " + base64.b64encode(f"preview:{password}".encode()).decode()
        self.assertEqual(self.resolve("external", Authorization=authorization).status_code, 204)
        path = "/v1/routes/external/demo"
        self.assertEqual(self.api.delete(path, headers={"Authorization": "Bearer " + "i" * 32}).status_code, 401)
        self.assertEqual(self.api.delete(path, headers={"Authorization": "Bearer " + "e" * 32}).status_code, 204)
        self.assertEqual(self.resolve("external").status_code, 404)
        self.assertEqual(self.resolve().status_code, 204)


if __name__ == "__main__":
    unittest.main()
