"""Shared outbound transport for reservation intent polling."""
import json
import urllib.request
from urllib.parse import urlsplit
from django.conf import settings


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def post(path, body):
    base = settings.CLOUD_SERVER_URL.rstrip('/')
    parsed = urlsplit(base)
    local = (getattr(settings, 'EDGE_REMOTE_CONTROL_ALLOW_LOCAL_HTTP', False)
             and parsed.scheme == 'http' and parsed.hostname in ('localhost', '127.0.0.1', '::1')
             and not parsed.username and not parsed.password)
    if (parsed.scheme != 'https' and not local) or not settings.CLOUD_SYNC_API_KEY:
        raise ValueError('HTTPS cloud URL and API key required (loopback HTTP needs explicit opt-in)')
    handlers = [NoRedirect]
    if local:
        handlers.append(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(base + path, data=json.dumps(body).encode(), headers={
        'Content-Type': 'application/json', 'Authorization': 'Bearer ' + settings.CLOUD_SYNC_API_KEY,
        'X-CompuLab-Site': settings.CLOUD_SYNC_SITE_ID}, method='POST')
    with urllib.request.build_opener(*handlers).open(request, timeout=settings.CLOUD_SYNC_TIMEOUT_SECONDS) as response:
        raw = response.read(2 * 1024 * 1024 + 1)
    if len(raw) > 2 * 1024 * 1024:
        raise ValueError('Response too large')
    return json.loads(raw)
