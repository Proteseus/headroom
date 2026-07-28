"""Extra accounts per quota provider (~/.headroom/accounts.json).

One Mac, two Claude logins: personal and work. The CLIs already support that —
`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, a second Cursor profile — by keeping each
login in its own directory. Headroom only ever looked at the default one, so
the second plan was invisible no matter how many windows you had open.

An account here is a *credential location plus a label*. Nothing more: no
token pasting, no sign-in flow, no Headroom-side session. You point a row at
`~/.claude-work` and the same fetcher that reads `~/.claude` reads that too.

The default login keeps the bare source id (`claude`), so history, pinned
order, burndown samples and every stored flag survive untouched — extra
accounts are strictly additive, and removing them all returns the machine to
exactly the shape it had before. Extra rows get `provider:slug` ids
(`claude:work`), which is what clients see in `sources[]` and `providers[]`.

`kind` says what the location *is*, and comes from the registry row:

    "dir"   the credential directory (Claude, Codex, Gemini) — the fetcher
            joins its own filename onto it, so filenames stay in the fetcher
    "file"  the credential store itself (Cursor / Windsurf `state.vscdb`)

The registry reads this file once at import: adding an account changes the
source list, which the poller, the sample schema and the client payloads are
all derived from, so it takes a host restart rather than a live rebuild.

Stdlib only.
"""

from __future__ import annotations

import json
import os
import re
import threading
from typing import NamedTuple, Optional

STORE_PATH = os.path.expanduser("~/.headroom/accounts.json")

# `provider:slug`. Colon rather than `#` so an id stays intact if it ever ends
# up in a query string instead of a JSON body.
SEPARATOR = ":"

SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,23}$")
MAX_LABEL = 40
# Per provider. A ceiling that no real desk hits, so a broken writer can't
# turn the poller into a fork bomb of HTTP calls.
MAX_PER_PROVIDER = 8

KIND_DIR = "dir"
KIND_FILE = "file"
KINDS = (KIND_DIR, KIND_FILE)


class Account(NamedTuple):
    """One extra login for a provider: where its credentials live, and a name.

    `root` is expanded and absolute — what fetchers open. `raw_root` is what
    the user typed, which is what Settings shows back and what round-trips to
    disk, so a `~` path keeps working when the home directory moves.
    """

    provider: str
    slug: str
    label: str
    root: str
    raw_root: str

    @property
    def id(self):
        return f"{self.provider}{SEPARATOR}{self.slug}"

    @property
    def cache_name(self):
        """Disk-cache basename: the last-good snapshot is per account."""
        return f"{self.provider}-{self.slug}"

    def child(self, name):
        """A file inside a `dir` account (fetchers own the filename)."""
        return os.path.join(self.root, name)

    def as_json(self):
        return {"slug": self.slug, "label": self.label, "root": self.raw_root}

    def payload(self):
        """Shape clients see in /setup → accounts[]."""
        return {
            "id": self.id,
            "provider": self.provider,
            "slug": self.slug,
            "label": self.label,
            "root": self.raw_root,
        }


_lock = threading.Lock()
_state = None


def split_id(source_id):
    """('claude', 'work') for an account row, ('claude', None) otherwise."""
    text = str(source_id or "")
    if SEPARATOR not in text:
        return text, None
    provider, _, slug = text.partition(SEPARATOR)
    return provider, (slug or None)


def is_account_id(source_id):
    return split_id(source_id)[1] is not None


def slugify(text):
    """Label → url-safe slug. Empty when nothing usable survives."""
    out = re.sub(r"[^a-z0-9]+", "-", str(text or "").strip().lower())
    return out.strip("-")[:24]


def _clean(provider, entry):
    if not isinstance(entry, dict):
        return None
    slug = slugify(entry.get("slug") or "")
    if not slug or not SLUG_RE.match(slug):
        return None
    raw = str(entry.get("root") or "").strip()
    if not raw:
        return None
    label = str(entry.get("label") or "").strip()[:MAX_LABEL] or slug.title()
    return Account(
        provider=provider,
        slug=slug,
        label=label,
        root=os.path.abspath(os.path.expanduser(raw)),
        raw_root=raw,
    )


def _load():
    try:
        with open(STORE_PATH) as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    out = {}
    for provider, entries in data.items():
        if not isinstance(entries, list):
            continue
        rows = []
        seen = set()
        for entry in entries[:MAX_PER_PROVIDER]:
            account = _clean(str(provider), entry)
            if account is None or account.slug in seen:
                continue
            seen.add(account.slug)
            rows.append(account)
        if rows:
            out[str(provider)] = tuple(rows)
    return out


def _save(state):
    data = {
        provider: [account.as_json() for account in rows]
        for provider, rows in sorted(state.items()) if rows
    }
    folder = os.path.dirname(STORE_PATH)
    os.makedirs(folder, exist_ok=True)
    tmp = STORE_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, STORE_PATH)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _state_locked():
    global _state
    if _state is None:
        _state = _load()
    return _state


def all_accounts():
    """{provider: (Account, …)} for every provider with extra logins."""
    with _lock:
        return dict(_state_locked())


def for_provider(provider):
    with _lock:
        return tuple(_state_locked().get(provider, ()))


def get(source_id):
    """The Account behind a `provider:slug` id, or None."""
    provider, slug = split_id(source_id)
    if slug is None:
        return None
    for account in for_provider(provider):
        if account.slug == slug:
            return account
    return None


def exists(source_id):
    return get(source_id) is not None


def credential_path(account, kind, filename=None):
    """Where this account's credential store actually is on disk.

    `dir` accounts join the fetcher's own filename; `file` accounts already
    point at the store. Returns None when the caller has no filename to join,
    which is the honest answer for a probe rather than a guess.
    """
    if account is None:
        return None
    if kind == KIND_FILE:
        return account.root
    return account.child(filename) if filename else None


def present(account, kind, filename=None):
    """True when the credential store this account names exists.

    Deliberately a file-existence check and nothing more — whether the token
    inside is valid is the fetcher's answer, and it reports it as a row error
    rather than as a missing source.
    """
    path = credential_path(account, kind, filename)
    return bool(path and os.path.isfile(path))


def add(provider, label, root, kind, slug=None):
    """Register one extra login. Returns the stored Account.

    Raises ValueError with something worth putting in front of a person:
    this is reached from Settings, where a typo in the path is the likeliest
    input and a silent drop would read as the save having failed.
    """
    provider = str(provider or "").strip()
    if not provider:
        raise ValueError("provider required")
    if kind not in KINDS:
        raise ValueError(f"{provider} does not support extra accounts")

    label = str(label or "").strip()[:MAX_LABEL]
    raw = str(root or "").strip()
    if not raw:
        raise ValueError("credential location required")
    resolved = os.path.abspath(os.path.expanduser(raw))
    if kind == KIND_DIR and not os.path.isdir(resolved):
        raise ValueError(f"{raw} is not a folder")
    if kind == KIND_FILE and not os.path.isfile(resolved):
        raise ValueError(f"{raw} is not a file")

    wanted = slugify(slug or label or os.path.basename(resolved.rstrip("/")))
    if not wanted or not SLUG_RE.match(wanted):
        raise ValueError("give the account a name (letters and numbers)")

    with _lock:
        state = _state_locked()
        rows = list(state.get(provider, ()))
        if len(rows) >= MAX_PER_PROVIDER:
            raise ValueError(
                f"{provider}: at most {MAX_PER_PROVIDER} extra accounts")
        # Same folder twice is the mistake that produces two identical rows
        # burning two API calls a minute against one login.
        for existing in rows:
            if existing.root == resolved:
                raise ValueError(
                    f"{existing.label} already reads {existing.raw_root}")
        taken = {row.slug for row in rows}
        unique = wanted
        suffix = 2
        while unique in taken:
            unique = f"{wanted}-{suffix}"[:24]
            suffix += 1
        account = Account(
            provider=provider,
            slug=unique,
            label=label or unique.title(),
            root=resolved,
            raw_root=raw,
        )
        rows.append(account)
        state[provider] = tuple(rows)
        _save(state)
        return account


def remove(source_id):
    """Drop one extra login. True when something was removed."""
    provider, slug = split_id(source_id)
    if slug is None:
        return False
    with _lock:
        state = _state_locked()
        rows = [row for row in state.get(provider, ()) if row.slug != slug]
        if len(rows) == len(state.get(provider, ())):
            return False
        if rows:
            state[provider] = tuple(rows)
        else:
            state.pop(provider, None)
        _save(state)
        return True


def reload():
    """Drop the cached file (tests, and after an out-of-band edit)."""
    global _state
    with _lock:
        _state = None
