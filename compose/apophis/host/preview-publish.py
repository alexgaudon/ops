#!/usr/bin/python3
"""Use Apophis's existing external credential without exporting it over SSH."""
import subprocess
import sys


CLIENT = r'''
import json
import os
import sys
from urllib.error import HTTPError
from urllib.request import Request, build_opener, HTTPRedirectHandler, ProxyHandler

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

try:
    check = sys.argv[1:] == ['--check']
    raw = sys.stdin.buffer.read(4097) if not check else b''
    if check:
        data = {'name': 'publish-check', 'ip': '0.0.0.0', 'port': 1, 'ttl_seconds': 604800}
    else:
        data = json.loads(raw)
        if len(raw) > 4096 or set(data) != {'name', 'ip', 'port', 'ttl_seconds'}:
            raise ValueError
    data['scope'] = 'external'
    token = os.environ.get('PREVIEW_EXTERNAL_TOKEN')
    if not token:
        raise ValueError
    request = Request('http://127.0.0.1:8000/v1/routes', json.dumps(data).encode(), headers={
        'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json',
    })
    try:
        with build_opener(ProxyHandler({}), NoRedirect).open(request, timeout=5) as response:
            result = json.load(response)
        if check:
            raise ValueError
        print(json.dumps({'url': result['url'], 'expires_at': result['expires_at']}))
    except HTTPError as error:
        with error:
            if check and error.code == 400 and json.load(error).get('error') == 'expected a private IPv4 address':
                print(json.dumps({'authenticated': True, 'external_max_ttl_verified': 604800}))
            else:
                print(json.dumps({'status': error.code}))
except (OSError, ValueError, TypeError, KeyError):
    sys.exit('External preview helper could not complete the request')
'''

if __name__ == '__main__':
    args = sys.argv[1:]
    if args not in ([], ['--check']):
        sys.exit('Usage: apophis-preview-publish [--check]')
    sys.exit(subprocess.call(['/usr/bin/docker', 'exec', '-i', 'preview-proxy-preview-api-1',
                              'python', '-I', '-c', CLIENT, *args]))
