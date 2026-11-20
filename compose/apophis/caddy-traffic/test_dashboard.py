import gzip
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import time
import unittest

from dashboard import endpoint, render, summarize


class TrafficTest(unittest.TestCase):
    def test_path_groups(self):
        self.assertEqual(endpoint('/api/v3/episode?key=secret'), '/api/v3/episode')
        self.assertEqual(endpoint('/Videos/123/stream'), '/Videos/:id/stream')
        self.assertEqual(endpoint('/assets/build-1.js'), '(static assets)')
        self.assertEqual(endpoint('/<example>'), '/:id')

    def test_current_and_rotated_windows(self):
        with TemporaryDirectory() as tmp:
            now = time.time()
            root = Path(tmp)

            def row(age, status):
                return json.dumps({'ts': now-age, 'status': status, 'size': 200,
                                   'request': {'host': 'test.local', 'uri': '/api?key=hidden',
                                               'method': 'GET'}}) + '\n'

            (root / 'access.log').write_text(row(60, 200) + 'truncated')
            with gzip.open(root / 'access-older.log.gz', 'wt') as f:
                f.write(row(4000, 503) + row(90000, 404))
            stats, gaps = summarize({'Public': root, 'Internal': root / 'missing'}, now)
            self.assertEqual(gaps, {'Internal'})
            self.assertEqual(stats[3600]['total'], 1)
            self.assertEqual(stats[86400]['total'], 2)
            page = render('/day', stats[86400], gaps, now)
            self.assertIn(b'GET /api', page)
            self.assertNotIn(b'hidden', page)
