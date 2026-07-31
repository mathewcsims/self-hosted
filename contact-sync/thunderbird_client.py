"""Minimal client for the Thunderbird MCP extension's local HTTP API —
shared by the one-time migration script and spoke_thunderbird.py. Talks
directly to the extension's JSON-RPC-over-HTTP endpoint (same protocol
its own mcp-bridge.cjs speaks), no MCP client/session needed — this is
what lets a headless launchd script use it at all, since contact-sync
never runs inside an interactive Claude session.

Connection info (port + a rotating 64-hex-char bearer token) is written
by the extension to a per-user temp file each time it starts; read fresh
on every call rather than cached, since a Thunderbird restart rotates it.
"""
import json
import os
import tempfile
import urllib.error
import urllib.request

CONNECTION_FILE = os.path.join(tempfile.gettempdir(), "thunderbird-mcp", "connection.json")

# Confirmed by grepping the extension's own source
# (extension/mcp_server/api.js): both duplicate "stfc.ac.uk Contacts"
# address books contain byte-identical data (same 21 names, same order,
# every field equally blank) — no technical way to tell them apart.
# abook-2.sqlite was ~10h more recently modified than abook-1.sqlite at
# the time this was written, the only signal available; if this later
# turns out backwards, this is the one line to change.
WORK_ADDRESS_BOOK_ID = "jsaddrbook://abook-2.sqlite"


class ThunderbirdUnavailable(Exception):
    """Thunderbird isn't running, or the extension isn't loaded/listening."""


def _connection():
    try:
        with open(CONNECTION_FILE) as f:
            conn = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        raise ThunderbirdUnavailable(
            f"no valid connection file at {CONNECTION_FILE} — "
            f"is Thunderbird running with the MCP extension loaded? ({e})"
        )
    if not conn.get("port") or not conn.get("token"):
        raise ThunderbirdUnavailable("connection file missing port/token")
    return conn["port"], conn["token"]


def call(method, params=None, timeout=30):
    port, token = _connection()
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params or {}}).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/", data=body, method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            resp = json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 403:
            raise ThunderbirdUnavailable("auth rejected (403) — token may be stale, retry")
        raise
    if "error" in resp:
        raise RuntimeError(f"{method} failed: {resp['error']}")
    return resp["result"]


def call_tool(name, arguments=None):
    result = call("tools/call", {"name": name, "arguments": arguments or {}})
    text = result["content"][0]["text"]
    parsed = json.loads(text)
    # Tool-level errors (e.g. schema validation) come back as {"error": ...}
    # inside a successful JSON-RPC response, not as a JSON-RPC error — the
    # updateContact call silently no-oped on this before it was checked
    # here (an explicit null value failed validation but still reported
    # "success" upstream).
    if isinstance(parsed, dict) and parsed.get("error") and not parsed.get("success", True):
        raise RuntimeError(f"{name} failed: {parsed['error']}")
    return parsed


# The extension caps searchContacts at 200 results, full stop. Verified
# empirically (asked for 50/199/201/300/1000 → got 50/199/200/200/200,
# always with hasMore: true) and stated in its own tool schema: "Maximum
# number of results to return (default 50, max 200)".
SEARCH_CAP = 200

# Seeds for partitioned enumeration. Letters and digits cover names and
# email addresses; searchContacts matches on either.
_SEED_PREFIXES = "abcdefghijklmnopqrstuvwxyz0123456789"

# How deep prefix expansion may go before giving up. Four characters means
# a single partition would need 200+ contacts sharing a 4-char prefix to
# defeat it — far beyond anything realistic here, and the failure is loud
# rather than silent if it ever happens.
_MAX_PREFIX_DEPTH = 4


def search_all(max_results=None):
    """Enumerate every contact across every address book.

    ── WHY THIS IS NOT ONE CALL ──────────────────────────────────────────
    An empty query does match unconditionally, so a single call is the
    obvious approach and is what this used to do. But the extension caps
    ANY search at 200 results, so once the library exceeded 200 contacts
    that call silently became a partial answer — and the old code's advice
    to "raise max_results" was simply wrong: the cap is server-side and
    ignores anything larger.

    That broke the ms_work pull on 2026-07-29 and every run after it, once
    the total crossed 200. There is no listContacts endpoint and no
    address-book filter (confirmed against tools/list), so searchContacts
    is the only bulk path there is.

    So: partition the search space instead. Query each letter/digit
    prefix, and recursively extend any prefix that still comes back
    truncated, until every partition fits under the cap. Results are
    deduplicated by contact id.

    The empty-query call is kept as an extra seed, not as the answer — it
    contributes up to 200 contacts for free and catches anything with
    neither a name nor an email for a prefix to match on.
    """
    if max_results is not None and max_results > SEARCH_CAP:
        raise ValueError(
            f"max_results={max_results} exceeds the extension's hard cap of "
            f"{SEARCH_CAP}; enumeration is partitioned instead — see search_all()"
        )

    found = {}
    truncated_prefixes = []

    def absorb(result):
        contacts = result["contacts"] if isinstance(result, dict) else result
        for c in contacts:
            found[c["id"]] = c
        return bool(isinstance(result, dict) and result.get("hasMore"))

    # Free seed: whatever the unconditional match returns before the cap.
    absorb(call_tool("searchContacts", {"query": "", "maxResults": SEARCH_CAP}))

    def walk(prefix):
        if absorb(call_tool("searchContacts",
                            {"query": prefix, "maxResults": SEARCH_CAP})):
            # This partition is still full — split it finer.
            if len(prefix) >= _MAX_PREFIX_DEPTH:
                truncated_prefixes.append(prefix)
                return
            for ch in _SEED_PREFIXES:
                walk(prefix + ch)

    for ch in _SEED_PREFIXES:
        walk(ch)

    if truncated_prefixes:
        # Loud rather than silently partial — a partial contact list would
        # look to the sync engine like contacts had been DELETED upstream.
        raise RuntimeError(
            "searchContacts still truncated at depth "
            f"{_MAX_PREFIX_DEPTH} for prefixes {truncated_prefixes!r} — "
            "more than 200 contacts share a prefix; enumeration is "
            "incomplete and the pull has been aborted rather than risk "
            "treating missing contacts as deletions"
        )

    return list(found.values())


def work_contacts():
    """searchContacts' bulk (empty-query) results use a lighter shape that
    doesn't reliably reflect email/phones/organization/etc — confirmed
    live: those fields stayed blank in search results even right after a
    real updateContact wrote them, while getContact showed the write
    correctly. Only good for enumerating IDs. With ~21 work contacts,
    fetching each one individually is cheap and gives accurate data."""
    stubs = [c for c in search_all() if c["addressBookId"] == WORK_ADDRESS_BOOK_ID]
    return [get_contact(c["id"]) for c in stubs]


def get_contact(contact_id):
    return call_tool("getContact", {"contactId": contact_id})


def update_contact(contact_id, **fields):
    return call_tool("updateContact", {"contactId": contact_id, **fields})
