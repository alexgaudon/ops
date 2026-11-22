from html.parser import HTMLParser
from pathlib import Path
import unittest


ROOT = Path(__file__).parent


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag == 'a':
            self.links.append(dict(attrs).get('href'))


class BookmarkTests(unittest.TestCase):
    def test_nas_bookmark_uses_internal_https_once(self):
        html = (ROOT / 'site/index.html').read_text()
        links = Links()
        links.feed(html)
        self.assertEqual(links.links.count('https://nas.internal.misery.systems/'), 1)
        self.assertNotIn('https://nas.amgau.xyz/', links.links)
        operations = html.split('<h3>Operations</h3>', 1)[1].split('</section>', 1)[0]
        self.assertIn('>NAS (Agnes)</a>', operations)

    def test_nas_route_restricts_lan_and_preserves_https_redirects(self):
        route = (ROOT.parent / 'caddy-internal/conf/routes/nas.caddy').read_text()
        self.assertTrue(route.startswith('nas.internal.misery.systems {'))
        self.assertIn('import internal_ui_tls', route)
        self.assertIn('@lan remote_ip 10.0.0.0/24', route)
        self.assertIn('handle @lan {\n\t\treverse_proxy 10.0.0.5:80', route)
        self.assertIn('handle {\n\t\trespond 403', route)
        self.assertIn('header_down Location', route)
        self.assertIn('"https://nas.internal.misery.systems$1"', route)


if __name__ == '__main__':
    unittest.main()
