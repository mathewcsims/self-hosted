import hashlib
import hmac
import http.server
import json
import os
import urllib.error
import urllib.parse
import urllib.request

WEBHOOK_SECRET = os.environ["WEBHOOK_SECRET"].encode()
APPRISE_NOTIFY_URL = "http://apprise:8000/notify/self-hosted"
MAX_BODY_BYTES = 1_000_000  # generous for a Vikunja task payload; guards against a bogus/huge Content-Length


def describe_event(event_name, data):
    """Returns (title, body, apprise_type) for a Vikunja webhook event."""
    task = data.get("task") or {}
    tasks = data.get("tasks") or []

    if event_name == "task.overdue" and task.get("title"):
        return "⚠️ Task overdue", f"**{task['title']}**", "warning"
    if event_name == "task.reminder.fired" and task.get("title"):
        return "🔔 Task reminder", f"**{task['title']}**", "info"
    if event_name == "tasks.overdue" and tasks:
        lines = "\n".join(f"- {t.get('title', '?')}" for t in tasks[:5])
        more = f"\n- (+{len(tasks) - 5} more)" if len(tasks) > 5 else ""
        return (
            f"⚠️ {len(tasks)} task(s) overdue",
            f"{lines}{more}",
            "warning",
        )
    return "Vikunja event", f"`{event_name}`", "info"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/webhook":
            self.send_response(404)
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

        signature = self.headers.get("X-Vikunja-Signature", "")
        expected = hmac.new(WEBHOOK_SECRET, raw_body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature, expected):
            self.send_response(401)
            self.end_headers()
            return

        try:
            payload = json.loads(raw_body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        event_name = payload.get("event_name", "unknown")
        title, body, notify_type = describe_event(event_name, payload.get("data") or {})

        notify_data = urllib.parse.urlencode(
            {"title": title, "body": body, "type": notify_type, "format": "markdown"}
        ).encode()
        req = urllib.request.Request(APPRISE_NOTIFY_URL, data=notify_data, method="POST")
        try:
            urllib.request.urlopen(req, timeout=10)
        except urllib.error.URLError:
            pass  # best-effort forward — Vikunja's webhook delivery isn't retried on our 5xx

        self.send_response(200)
        self.end_headers()

    def log_message(self, format, *args):
        pass  # silence BaseHTTPRequestHandler's default per-request access log


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
