"""Shared urllib plumbing for Headroom fetchers.

Every provider talks to a different API with different auth headers, but the
mechanics never change: glue a query onto the URL, encode a body, set Accept
and User-Agent, open with a timeout, decode JSON that might be empty. That is
what lives here. What does *not* live here is error policy — some callers want
the `HTTPError` to escape so `keep_stale` can shape the message, others want
the status code so they can tell a 401 from a 429. `request` returns the
status; `request_json` drops it. Neither swallows an exception.

Stdlib only.
"""

from __future__ import annotations

import json
import urllib.parse
import urllib.request

DEFAULT_UA = "Headroom/1"
DEFAULT_TIMEOUT_S = 15


def build_url(url: str, query=None) -> str:
    if not query:
        return url
    joiner = "&" if "?" in url else "?"
    return url + joiner + urllib.parse.urlencode(query, doseq=True)


def _body_and_type(json_body, form_body):
    if json_body is not None:
        return json.dumps(json_body).encode(), "application/json"
    if form_body is not None:
        return (
            urllib.parse.urlencode(form_body).encode(),
            "application/x-www-form-urlencoded",
        )
    return None, None


def request(
    url,
    *,
    auth=None,
    headers=None,
    query=None,
    json_body=None,
    form_body=None,
    method=None,
    timeout=DEFAULT_TIMEOUT_S,
    accept="application/json",
    user_agent=DEFAULT_UA,
):
    """Perform one request and return `(status, parsed_body_or_None)`.

    `auth` is the full Authorization header value, so callers keep whatever
    scheme their API wants ("Bearer x", "token x", Zed's "<id> <token>").
    `headers` is merged last and wins, which is how Copilot spoofs an editor
    User-Agent without a second code path.
    """
    data, content_type = _body_and_type(json_body, form_body)
    final = {"Accept": accept, "User-Agent": user_agent}
    if auth:
        final["Authorization"] = auth
    if content_type:
        final["Content-Type"] = content_type
    if headers:
        final.update(headers)

    req = urllib.request.Request(
        build_url(url, query), data=data, headers=final, method=method
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode()
        # A 204 or an empty 200 is a valid answer, not a parse failure.
        return resp.getcode(), (json.loads(raw) if raw else None)


def request_json(url, **kwargs):
    """`request` for callers that only care about the body."""
    return request(url, **kwargs)[1]
