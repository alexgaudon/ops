"""Server-side, read-only media dashboard widgets."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from functools import lru_cache
from html import escape
import json
import os
import re
from threading import Lock
from time import monotonic
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


try:
    DISPLAY_TZ = ZoneInfo('America/St_Johns')
    TZ_LABEL = 'St. John’s time'
except ZoneInfoNotFoundError:
    DISPLAY_TZ, TZ_LABEL = timezone.utc, 'UTC'

# Caddy's LAN ACL intentionally excludes the Docker bridge. Use the exact LAN
# upstreams for the two configured internal origins, without changing the ACL.
DIRECT = {
    ('SONARR', 'https://sonarr.internal.misery.systems'): 'http://10.0.0.5:8989',
    ('RADARR', 'https://radarr.internal.misery.systems'): 'http://10.0.0.5:7878',
}
ORIGINS = {
    'JELLYFIN': {'https://jellyfin.amgau.com', 'https://jellyfin.misery.systems'},
    'SONARR': {'https://sonarr.internal.misery.systems'},
    'RADARR': {'https://radarr.internal.misery.systems'},
}
MAX_JSON = 4 * 1024 * 1024
MAX_POSTER = 512 * 1024
IMAGE_KEY = re.compile(r'[a-f0-9]{32}/[a-f0-9]{32}', re.I | re.ASCII)
LOCK = Lock()
snapshot = None
visible_posters = frozenset()


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


def open_media(service, path, params=None, accept='application/json'):
    origin = os.environ.get(service + '_URL', '').rstrip('/')
    key = os.environ.get(service + '_API_KEY', '').strip()
    if not origin or not key:
        raise ValueError('Not configured')
    if origin not in ORIGINS[service]:
        raise ValueError('Unexpected origin')
    base = DIRECT.get((service, origin), origin)
    if service == 'JELLYFIN':
        headers = {'Authorization': f'MediaBrowser Token="{key}"'}
    else:
        headers = {'X-Api-Key': key}
    query = '?' + urlencode(params) if params else ''
    req = Request(base + path + query, headers={'Accept': accept, **headers})
    return build_opener(ProxyHandler({}), NoRedirect).open(req, timeout=4)


def fetch(service, path, params=None):
    with open_media(service, path, params) as response:
        body = response.read(MAX_JSON + 1)
    if len(body) > MAX_JSON:
        raise ValueError('Media response is too large')
    return json.loads(body)


def text(value):
    return escape(str(value or '')[:180])


def note(message):
    return f'<p class="muted">{text(message)}</p>'


def rows(items, empty):
    if not items:
        return note(empty)
    return '<ul class="media-list">' + ''.join(
        f'<li><strong>{text(title)}</strong><small>{text(detail)}</small></li>'
        for title, detail in items
    ) + '</ul>'


def date_value(value):
    if not isinstance(value, str) or not value[:10]:
        return None
    try:
        at = datetime.fromisoformat(value)
    except ValueError:
        return None
    return at


def upcoming(entries, today, kind):
    result = []
    last_day = today + timedelta(days=30)
    for entry in entries:
        if kind == 'TV':
            at = date_value(entry.get('airDateUtc') or entry.get('airDate'))
            if not at:
                continue
            local = at.astimezone(DISPLAY_TZ) if at.tzinfo is not None else at
            show = (entry.get('series') or {}).get('title') or 'Unknown series'
            detail = ' · '.join(part for part in (entry.get('title'), local.strftime('%b %d, %H:%M') if at.tzinfo else local.strftime('%b %d')) if part)
            if today <= local.date() <= last_day:
                result.append((local.replace(tzinfo=None), show, detail))
        else:
            for field, label in [('inCinemas', 'In cinemas'), ('digitalRelease', 'Digital'), ('physicalRelease', 'Physical')]:
                at = date_value(entry.get(field))
                if at and today <= at.date() <= last_day:
                    result.append((at.replace(tzinfo=None), entry.get('title') or 'Untitled', f'{label} · {at:%b %d}'))
    return rows([(title, detail) for _, title, detail in sorted(set(result))[:8]],
                'No releases scheduled in the next 30 days.')


def calendar(service):
    today = datetime.now(DISPLAY_TZ).date()
    query = {'start': (today - timedelta(days=1)).isoformat(),
             'end': (today + timedelta(days=31)).isoformat()}
    if service == 'SONARR':
        query['includeSeries'] = 'true'
    data = fetch(service, '/api/v3/calendar', query)
    return upcoming(data, today, 'TV' if service == 'SONARR' else 'Movies')


def sessions():
    data = fetch('JELLYFIN', '/Sessions')
    active = []
    for session in data:
        item = session.get('NowPlayingItem') or {}
        if item.get('Name'):
            state = 'Paused' if (session.get('PlayState') or {}).get('IsPaused') else 'Playing'
            # Show the Jellyfin username, but omit device names and addresses.
            details = [session.get('UserName'), state, item['Name'] if item.get('SeriesName') else None]
            active.append((item.get('SeriesName') or item['Name'], ' · '.join(str(part) for part in details if part)))
    return rows(active[:8], 'No active playback sessions.')


def counts():
    data = fetch('JELLYFIN', '/Items/Counts')
    return '<dl class="library">' + ''.join(
        f'<div><dt>{label}</dt><dd>{data[key]:,}</dd></div>'
        for key, label in [('MovieCount', 'Movies'), ('SeriesCount', 'TV shows'), ('EpisodeCount', 'Episodes')]
    ) + '</dl>'


def episodes():
    global visible_posters
    visible_posters = frozenset()
    data = fetch('JELLYFIN', '/Items', {'Recursive': 'true', 'IncludeItemTypes': 'Episode',
                 'SortBy': 'DateCreated', 'SortOrder': 'Descending', 'Limit': 8})
    items = data['Items'][:8]
    if not items:
        return note('No episodes found.')
    cards, keys = [], set()
    for item in items:
        key = f'{item.get("SeriesId")}/{item.get("SeriesPrimaryImageTag")}'
        image = ''
        if IMAGE_KEY.fullmatch(key):
            keys.add(key)
            image = f'<img src="/media/posters/{key}" alt="" width="240" height="360" loading="lazy" decoding="async">'
        cards.append(f'<li><div class="poster-art">{image}</div><div class="poster-caption">'
                     f'<strong>{text(item.get("SeriesName") or "Unknown series")}</strong>'
                     f'<small>{text(item.get("Name"))}</small></div></li>')
    visible_posters = frozenset(keys)
    return '<ul class="poster-strip">' + ''.join(cards) + '</ul>'


def poster(key):
    if not IMAGE_KEY.fullmatch(key) or key not in visible_posters:
        return None
    try:
        return load_poster(key)
    except HTTPError as error:
        error.close()
        return None
    except (OSError, ValueError):
        return None


@lru_cache(maxsize=32)
def load_poster(key):
    series, tag = key.split('/')
    with open_media('JELLYFIN', f'/Items/{series}/Images/Primary',
                    {'maxWidth': 240, 'quality': 85, 'format': 'jpg', 'tag': tag}, 'image/jpeg') as response:
        if response.headers.get_content_type() != 'image/jpeg':
            raise ValueError('Unexpected poster format')
        image = response.read(MAX_POSTER + 1)
    if not image.startswith(b'\xff\xd8\xff') or len(image) > MAX_POSTER:
        raise ValueError('Invalid poster')
    return image


def widget(task):
    name, service, fn = task
    try:
        return name, fn()
    except HTTPError as error:
        with error:
            if error.code in (401, 403):
                return name, note(f'{service.title()} rejected the dashboard credentials ({error.code}).')
        return name, note(f'{service.title()} is unavailable.')
    except (OSError, ValueError, AttributeError, TypeError, KeyError):
        return name, note(f'{service.title()} data is unavailable.')


def media_widgets():
    global snapshot
    with LOCK:
        if snapshot is None or monotonic() >= snapshot[0]:
            tasks = [('UPCOMING_TV', 'SONARR', lambda: calendar('SONARR')),
                     ('UPCOMING_MOVIES', 'RADARR', lambda: calendar('RADARR')),
                     ('JELLYFIN_SESSIONS', 'JELLYFIN', sessions),
                     ('JELLYFIN_COUNTS', 'JELLYFIN', counts),
                     ('RECENT_EPISODES', 'JELLYFIN', episodes)]
            with ThreadPoolExecutor(max_workers=len(tasks)) as pool:
                data = dict(pool.map(widget, tasks))
            data['MEDIA_TIMEZONE'] = TZ_LABEL
            snapshot = monotonic() + 120, data
        return snapshot[1]
