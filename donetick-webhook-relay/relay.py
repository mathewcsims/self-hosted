"""Bridges Donetick's webhook payload shape to Apprise's /notify shape.

Donetick posts its own event envelope:

    {"type": "task.reminder", "timestamp": "...", "data": {"chore": {...}, ...}}

Apprise wants title/body/type. Posting Donetick's payload straight at it
returns 400 {"error": "Payload lacks minimum requirements"} — confirmed
live before writing this — so something has to translate. Same job, and
deliberately the same shape, as ../vikunja-webhook-relay/relay.py.

── AUTHENTICATION IS A URL SECRET, NOT AN HMAC ───────────────────────────
The Vikunja relay verifies an HMAC signature because Vikunja signs its
webhooks. DONETICK DOES NOT SIGN ANYTHING — it sends the JSON body with a
bare Content-Type header and nothing else (confirmed by reading
internal/events/producer.go's processEvent at the pinned tag). So the only
thing that can authenticate a request here is a secret carried in the URL,
which is why the path is /hook/<secret> and Donetick's configured
webhook_url embeds it.

That secret is therefore the whole authentication story, and it is why the
Caddy site in front of this is ALSO LAN/tailnet-gated: a URL secret leaks
into logs and history far more readily than a signature does, so it is not
trusted on its own.
"""
import datetime
import hmac
import http.server
import json
import os
import urllib.error
import urllib.parse
import urllib.request

WEBHOOK_SECRET = os.environ["WEBHOOK_SECRET"]
APPRISE_NOTIFY_URL = "http://apprise:8000/notify/self-hosted"
MAX_BODY_BYTES = 1_000_000


def log(msg):
    # The only visibility into whether Donetick is actually delivering —
    # BaseHTTPRequestHandler's own access log is silenced below. The Vikunja
    # relay added this after a "reminders not appearing" investigation had
    # no log evidence to work from; same reasoning applies here.
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    print(f"[{ts}] {msg}", flush=True)


def describe_event(event_type, data):
    """Returns (title, body, apprise_type) for a Donetick event.

    Event types come from internal/events/producer.go: task.created,
    task.reminder, task.completed, subtask.completed, task.skipped,
    thing.changed.
    """
    chore = (data or {}).get("chore") or {}
    name = chore.get("name") or "(unnamed task)"
    who = (data or {}).get("display_name") or (data or {}).get("username") or ""

    if event_type == "task.reminder":
        return "🔔 Task reminder", f"**{name}**", "info"
    if event_type == "task.completed":
        by = f"\n\nCompleted by {who}" if who else ""
        return "✅ Task completed", f"**{name}**{by}", "success"
    if event_type == "subtask.completed":
        return "☑️ Subtask completed", f"**{name}**", "success"
    if event_type == "task.skipped":
        return "⏭️ Task skipped", f"**{name}**", "warning"
    if event_type == "task.created":
        return "🆕 Task created", f"**{name}**", "info"
    if event_type == "thing.changed":
        return "🔀 Thing changed", f"`{json.dumps(data)[:300]}`", "info"
    # Unknown event: forward it rather than swallow it, so a new upstream
    # event type shows up as something odd in Discord instead of silence.
    return "Donetick event", f"`{event_type}`", "info"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        prefix = "/hook/"
        if not self.path.startswith(prefix):
            self.send_response(404)
            self.end_headers()
            return

        # Constant-time compare — the secret is the only credential here.
        supplied = self.path[len(prefix):]
        if not hmac.compare_digest(supplied, WEBHOOK_SECRET):
            log(f"REJECTED bad secret from {self.client_address[0]}")
            self.send_response(401)
            self.end_headers()
            return

        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self.send_response(400)
            self.end_headers()
            return
        if length > MAX_BODY_BYTES:
            self.send_response(413)
            self.end_headers()
            return
        raw_body = self.rfile.read(length)

        try:
            payload = json.loads(raw_body)
        except json.JSONDecodeError:
            log(f"REJECTED invalid JSON, {len(raw_body)} bytes")
            self.send_response(400)
            self.end_headers()
            return

        event_type = payload.get("type", "unknown")
        title, body, notify_type = describe_event(event_type, payload.get("data") or {})
        log(f"received type={event_type!r} -> title={title!r}")

        notify_data = urllib.parse.urlencode(
            {"title": title, "body": body, "type": notify_type, "format": "markdown"}
        ).encode()
        req = urllib.request.Request(APPRISE_NOTIFY_URL, data=notify_data, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                log(f"forwarded to Apprise, status={resp.status}")
        except urllib.error.URLError as e:
            # Best-effort: Donetick drops the event on a non-2xx and does not
            # retry, so returning 200 regardless avoids nothing — but logging
            # loudly is what makes a silent failure findable.
            log(f"APPRISE FORWARD FAILED: {e}")

        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        # Health endpoint for Uptime Kuma. Deliberately unauthenticated and
        # says nothing beyond "the process is up".
        if self.path == "/health":
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, format, *args):
        pass  # silence the default per-request access log


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
