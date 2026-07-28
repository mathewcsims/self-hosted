"""
Wanderer -> Owl relay: on every new trail Wanderer creates, posts a Memo to
Owl (usememos.com) linking back to the ride.

Wanderer has no webhook system at all (confirmed by reading its actual
source) — the only usable "new record" signal is PocketBase's own built-in
realtime API (Server-Sent Events at /api/realtime), which lives on the `db`
container, not the public `web` app. This relay holds that SSE connection
open, subscribes to the `trails` collection, and reacts to both `create`
and `update` events.

Authenticates as the PocketBase superuser (created during Wanderer's own
setup, see wanderer/compose.yaml's header comment) rather than a scoped
user token — trails default to private (`viewRule: id = @request.auth.id`),
and the superuser is the only account that can see every trail's realtime
events regardless of owner, same pragmatic tradeoff as Karakeep only ever
using its full MEILI_MASTER_KEY rather than a scoped index key.

Best-effort forward, same as vikunja-webhook-relay's Apprise forward: a
failed Owl post is logged, not retried or queued. If this container is
down when a ride is created, that event is simply missed — acceptable for
a personal convenience feature, not something building a retry queue is
worth the complexity for.

Posting is DEBOUNCED, not fired on a fixed delay after `create` — a fixed
delay was tried first and rejected (confirmed live, 2026-07-28): a human
manually reviewing/editing a freshly imported trail (fixing the name,
adding photos, correcting stats) can easily take far longer than any
sensible fixed wait, and firing partway through an edit posts a
half-finished entry. Instead, every `create` or `update` event for a
trail resets a per-trail timer; the trail is only re-fetched and posted
once DEBOUNCE_SECONDS have passed with NO further events for it — however
long the editing session actually takes. Each trail is posted at most
once per process lifetime (a restart mid-debounce silently drops the
pending post, same "best effort" tradeoff as everything else here).
"""

import base64
import datetime
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.client import HTTPConnection

DB_HOST = os.environ.get("DB_HOST", "db")
DB_PORT = int(os.environ.get("DB_PORT", "8090"))
SUPERUSER_EMAIL = os.environ["WANDERER_SUPERUSER_EMAIL"]
SUPERUSER_PASSWORD = os.environ["WANDERER_SUPERUSER_PASSWORD"]
WANDERER_PUBLIC_URL = os.environ.get("WANDERER_PUBLIC_URL", "https://wanderer.mathewcsims.uk")
WANDERER_USERNAME = os.environ.get("WANDERER_USERNAME", "mathewcsims")

OWL_URL = os.environ.get("OWL_URL", "http://10.0.1.14:5231")
MEMOS_TOKEN = os.environ["MEMOS_TOKEN"]

RECONNECT_DELAY_SECONDS = 15
# How long a trail must go untouched (no create/update event) before it's
# considered "done" and posted. Deliberately generous — a manual editing
# session is the thing this is guarding against, not network jitter.
DEBOUNCE_SECONDS = int(os.environ.get("DEBOUNCE_SECONDS", str(15 * 60)))


def log(msg):
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    print(f"[{ts}] {msg}", flush=True)


def db_request(method, path, body=None, token=None):
    conn = HTTPConnection(DB_HOST, DB_PORT, timeout=15)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = token
    data = json.dumps(body).encode() if body is not None else None
    conn.request(method, path, body=data, headers=headers)
    resp = conn.getresponse()
    raw = resp.read()
    conn.close()
    if resp.status >= 400:
        raise RuntimeError(f"{method} {path} -> {resp.status}: {raw[:300]!r}")
    return json.loads(raw) if raw else {}


def authenticate():
    result = db_request(
        "POST",
        "/api/collections/_superusers/auth-with-password",
        {"identity": SUPERUSER_EMAIL, "password": SUPERUSER_PASSWORD},
    )
    return result["token"]


def format_duration(seconds):
    # None/0 genuinely means "not available", not "zero minutes" — confirmed
    # upstream bug (github.com/flomp/wanderer): KML->GPX conversion parses
    # per-point timestamps but discards them before building GPX points, so
    # duration computes as a real, permanent 0 for any KML-sourced trail
    # (not a race with this relay — Wanderer's own backend computes and
    # stores 0 synchronously at creation, confirmed by reading its source).
    # GPX imports are unaffected. Show "n/a" rather than a false "0m".
    seconds = int(seconds or 0)
    if seconds == 0:
        return "n/a"
    hours, rem = divmod(seconds, 3600)
    minutes = rem // 60
    if hours:
        return f"{hours}h{minutes:02d}m"
    return f"{minutes}m"


def trail_link(trail_id):
    # Not a plain /trail/{id} path — confirmed live (2026-07-28) that
    # Wanderer's actual viewer route is /trail/view/@{username}@{host}/{id},
    # an ActivityPub-style actor handle embedded in the URL, not just the
    # trail ID. WANDERER_USERNAME is the app account's own username (not
    # its email's local part — confirmed different: username is
    # "mathewcsims", the login email is "mat@mathewcsims.uk").
    host = urllib.parse.urlparse(WANDERER_PUBLIC_URL).netloc
    return f"{WANDERER_PUBLIC_URL}/trail/view/@{WANDERER_USERNAME}@{host}/{trail_id}"


def post_memo(trail, pb_token=None):
    name = trail.get("name") or "Untitled ride"
    date = trail.get("date", "")[:10]
    distance_km = (trail.get("distance") or 0) / 1000
    elevation_gain = trail.get("elevation_gain") or 0
    duration = format_duration(trail.get("duration"))
    trail_id = trail["id"]
    link = trail_link(trail_id)

    # Memos has no separate title field — a memo's displayed title is
    # derived from a leading Markdown heading. A plain bold-text first line
    # rendered with no title at all in Owl's UI; a real `#` heading is what
    # Memos' own frontend looks for.
    #
    # The trail link is wrapped as an explicit [text](url) Markdown link,
    # not posted as a bare URL. Confirmed live (2026-07-28): Memos' own
    # bare-URL auto-linkifier fails on Wanderer's URL shape specifically —
    # the ActivityPub-style @user@host segment in the path trips it up,
    # and the memo comes back from Memos' own API with
    # `property.hasLink: false`, meaning Memos itself never recognized it
    # as a link at all, regardless of how correct the raw text is.
    # Explicit link syntax is parsed as a real link node directly, bypasses
    # that bare-URL heuristic entirely, and is unaffected by anything in
    # the URL's own path.
    content = (
        f"# 🚴 {name}\n"
        f"📅 {date} · 📏 {distance_km:.1f} km · ⛰️ {elevation_gain:.0f}m gain · ⏱️ {duration}\n"
        f"🔗 [View on Wanderer]({link})\n"
        f"#cycling #wanderer"
    )

    req = urllib.request.Request(
        f"{OWL_URL}/api/v1/memos",
        data=json.dumps({"content": content, "visibility": "PRIVATE"}).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {MEMOS_TOKEN}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            memo = json.loads(resp.read())
            log(f"posted memo for trail {trail_id!r} ({name!r}), status={resp.status}")
    except urllib.error.URLError as e:
        log(f"MEMO POST FAILED for trail {trail_id!r}: {e}")
        return

    photos = trail.get("photos") or []
    if photos and pb_token:
        attach_photos(memo["name"], trail_id, photos, pb_token)


def fetch_trail_file(trail_id, filename, token):
    conn = HTTPConnection(DB_HOST, DB_PORT, timeout=15)
    conn.request(
        "GET",
        f"/api/files/trails/{trail_id}/{urllib.parse.quote(filename)}",
        headers={"Authorization": token},
    )
    resp = conn.getresponse()
    raw = resp.read()
    conn.close()
    if resp.status >= 400:
        raise RuntimeError(f"GET file {filename!r} -> {resp.status}: {raw[:200]!r}")
    return raw, resp.getheader("Content-Type", "application/octet-stream")


def attach_photos(memo_name, trail_id, filenames, pb_token):
    # Wanderer's own auto-generated route-map image ("route_*.webp") lives
    # in the same `photos` field as real uploaded photos — both are
    # attached; there's no field to distinguish them, and the route map is
    # a reasonable "cover image" in its own right when no real photos
    # exist.
    for filename in filenames:
        try:
            content_bytes, mime_type = fetch_trail_file(trail_id, filename, pb_token)
        except Exception as e:
            log(f"FAILED to fetch photo {filename!r} for trail {trail_id!r}: {e}")
            continue

        req = urllib.request.Request(
            f"{OWL_URL}/api/v1/attachments",
            data=json.dumps(
                {
                    "filename": filename,
                    "type": mime_type,
                    "content": base64.b64encode(content_bytes).decode(),
                    "memo": memo_name,
                }
            ).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {MEMOS_TOKEN}",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                log(f"attached photo {filename!r} to {memo_name}, status={resp.status}")
        except urllib.error.URLError as e:
            log(f"PHOTO ATTACH FAILED for {filename!r} on {memo_name}: {e}")


class Debouncer:
    """One timer per trail id. Every touch() call cancels any pending
    timer for that id and starts a fresh one — the trail only actually
    fires once DEBOUNCE_SECONDS pass with no further touch() calls.
    Fires at most once per trail for this process's lifetime.
    """

    def __init__(self, delay_seconds):
        self.delay_seconds = delay_seconds
        self._timers = {}
        self._posted = set()
        self._lock = threading.Lock()

    def touch(self, trail_id, name):
        with self._lock:
            if trail_id in self._posted:
                return
            existing = self._timers.get(trail_id)
            if existing is not None:
                existing.cancel()
            timer = threading.Timer(self.delay_seconds, self._fire, args=(trail_id, name))
            timer.daemon = True
            self._timers[trail_id] = timer
            timer.start()

    def _fire(self, trail_id, name):
        with self._lock:
            if trail_id in self._posted:
                return
            self._posted.add(trail_id)
            self._timers.pop(trail_id, None)
        log(f"trail {trail_id!r} ({name!r}) quiet for {self.delay_seconds}s, posting")
        try:
            token = authenticate()
            record = db_request("GET", f"/api/collections/trails/records/{trail_id}", token=token)
            post_memo(record, pb_token=token)
        except Exception as e:
            log(f"FAILED to re-fetch/post trail {trail_id!r} ({name!r}): {e}")


def parse_sse_stream(resp):
    """Yields (event_name, data_dict) for each SSE event in the stream."""
    event_name = None
    data_lines = []
    while True:
        line = resp.readline()
        if not line:
            return  # connection closed
        line = line.decode("utf-8", errors="replace").rstrip("\n").rstrip("\r")
        if line == "":
            if data_lines:
                raw = "\n".join(data_lines)
                try:
                    yield event_name, json.loads(raw)
                except json.JSONDecodeError:
                    log(f"malformed SSE data, skipping: {raw[:200]!r}")
            event_name = None
            data_lines = []
            continue
        if line.startswith("event:"):
            event_name = line[len("event:"):].strip()
        elif line.startswith("data:"):
            data_lines.append(line[len("data:"):].strip())


def run_once(debouncer):
    token = authenticate()
    log("authenticated as superuser")

    conn = HTTPConnection(DB_HOST, DB_PORT, timeout=None)
    conn.request(
        "GET",
        "/api/realtime",
        headers={"Accept": "text/event-stream"},
    )
    resp = conn.getresponse()
    if resp.status != 200:
        raise RuntimeError(f"GET /api/realtime -> {resp.status}")

    client_id = None
    subscribed = False
    for event_name, data in parse_sse_stream(resp):
        if event_name == "PB_CONNECT":
            client_id = data["clientId"]
            log(f"got clientId={client_id}, subscribing to trails")
            db_request(
                "POST",
                "/api/realtime",
                {"clientId": client_id, "subscriptions": ["trails"]},
                token=token,
            )
            subscribed = True
            log("subscribed to trails collection")
            continue

        if not subscribed:
            continue  # ignore anything before the subscription confirms

        if event_name == "trails" and data.get("action") in ("create", "update"):
            record = data.get("record") or {}
            trail_id = record.get("id")
            name = record.get("name")
            log(f"trail {data['action']}: {trail_id!r} {name!r} — debounce reset")
            debouncer.touch(trail_id, name)

    log("SSE stream closed by server")


def main():
    debouncer = Debouncer(DEBOUNCE_SECONDS)
    while True:
        try:
            run_once(debouncer)
        except Exception as e:
            log(f"connection error: {e}")
        log(f"reconnecting in {RECONNECT_DELAY_SECONDS}s")
        time.sleep(RECONNECT_DELAY_SECONDS)


if __name__ == "__main__":
    main()
