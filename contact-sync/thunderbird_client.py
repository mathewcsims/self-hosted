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


def search_all(max_results=200):
    """Empty query returns every contact across every address book
    (confirmed against the extension's source — an empty query matches
    unconditionally) — the only bulk-enumeration path available; there's
    no dedicated list/enumerate endpoint."""
    result = call_tool("searchContacts", {"query": "", "maxResults": max_results})
    contacts = result["contacts"] if isinstance(result, dict) else result
    if isinstance(result, dict) and result.get("hasMore"):
        raise RuntimeError(
            f"searchContacts truncated at {max_results} — raise max_results, "
            f"total contact count across all address books exceeds it"
        )
    return contacts


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
