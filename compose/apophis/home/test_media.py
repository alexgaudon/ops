from datetime import date
from io import BytesIO
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

import media


class MediaTests(unittest.TestCase):
    def test_posters_are_limited_to_current_series_art(self):
        key = 'a' * 32 + '/' + 'b' * 32
        with patch.object(media, 'visible_posters', frozenset()), patch.object(media, 'fetch', return_value={
            'Items': [{'SeriesId': 'a' * 32, 'SeriesPrimaryImageTag': 'b' * 32, 'Name': '<Title>'}]
        }), patch.object(media, 'load_poster', return_value=b'jpeg') as load:
            page = media.episodes()
            self.assertIn('/media/posters/' + key, page)
            self.assertIn('&lt;Title&gt;', page)
            self.assertIsNone(media.poster('c' * 32 + '/' + 'b' * 32))
            self.assertEqual(media.poster(key), b'jpeg')
            load.assert_called_once_with(key)

    def test_calendar_filters_and_escapes(self):
        result = media.upcoming([
            {'title': '<Tomorrow>', 'inCinemas': '2026-11-21'},
            {'title': 'Old title', 'digitalRelease': '2026-11-01'},
        ], date(2026, 11, 20), 'Movies')
        self.assertIn('&lt;Tomorrow&gt;', result)
        self.assertNotIn('Old title', result)

    def test_sessions_show_username_without_device_or_address(self):
        with patch.object(media, 'fetch', return_value=[
            {'UserName': '<viewer>', 'DeviceName': 'private-device', 'RemoteEndPoint': '192.0.2.1',
             'NowPlayingItem': {'Name': 'Episode', 'SeriesName': 'Show'}, 'PlayState': {'IsPaused': True}},
            {'NowPlayingItem': {'Name': 'Film'}},
            {'UserName': 'idle-viewer'},
        ]):
            result = media.sessions()
        self.assertIn('&lt;viewer&gt; · Paused · Episode', result)
        self.assertIn('<strong>Film</strong><small>Playing</small>', result)
        self.assertNotIn('<viewer>', result)
        self.assertNotIn('private-device', result)
        self.assertNotIn('192.0.2.1', result)
        self.assertNotIn('idle-viewer', result)

    def test_bad_key_is_not_an_empty_library(self):
        error = HTTPError('https://example.invalid', 401, '', {}, BytesIO())
        with patch.object(media, 'fetch', side_effect=error):
            _, result = media.widget(('counts', 'JELLYFIN', media.counts))
        self.assertIn('rejected the dashboard credentials (401)', result)
