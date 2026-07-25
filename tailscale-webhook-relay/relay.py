import datetime
import hashlib
import hmac
import http.server
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

WEBHOOK_SECRET = os.environ["WEBHOOK_SECRET"].encode()
MAX_CLOCK_SKEW_SECONDS = 5 * 60  # Tailscale doesn't document a tolerance;
# matches the common Stripe-style webhook convention this signature scheme
# is otherwise identical to (t=<ts>,v1=<hmac>) — rejects stale/replayed
# deliveries without being so tight a slow network hop causes false 401s.


def log(msg):
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    print(f"[{ts}] {msg}", flush=True)


APPRISE_NOTIFY_URL = "http://apprise:8000/notify/self-hosted"
MAX_BODY_BYTES = 1_000_000

# (title prefix, apprise type) per event type. Anything not listed still
# gets forwarded (falls through to the default below) rather than dropped —
# an unrecognized-but-subscribed event is exactly the kind of thing worth
# seeing, not silently discarding.
EVENT_STYLES = {
    "nodeNeedsApproval": ("🔔 Device needs approval", "warning"),
    "nodeNeedsSignature": ("🔔 Device needs signature", "warning"),
    "userNeedsApproval": ("🔔 User needs approval", "warning"),
    "nodeKeyExpired": ("⚠️ Node key expired", "warning"),
    "nodeKeyExpiringInOneDay": ("⚠️ Node key expiring in 1 day", "warning"),
    "policyUpdate": ("⚠️ ACL policy changed", "warning"),
    "exitNodeIPForwardingNotEnabled": ("⚠️ Exit node misconfigured (IP forwarding off)", "warning"),
    "subnetIPForwardingNotEnabled": ("⚠️ Subnet router misconfigured (IP forwarding off)", "warning"),
    "webhookUpdated": ("⚠️ This webhook's config changed", "warning"),
    "webhookDeleted": ("⚠️ A webhook was deleted", "warning"),
    "nodeCreated": ("✅ New device", "info"),
    "nodeApproved": ("✅ Device approved", "info"),
    "nodeDeleted": ("🗑️ Device removed", "info"),
    "nodeSigned": ("✅ Device signed", "info"),
    "userApproved": ("✅ User approved", "info"),
    "userCreated": ("✅ New user", "info"),
    "userRoleUpdated": ("ℹ️ User role changed", "info"),
    "test": ("🧪 Tailscale webhook test", "info"),
}


def describe_event(evt):
    event_type = evt.get("type", "unknown")
    prefix, notify_type = EVENT_STYLES.get(event_type, (f"Tailscale: {event_type}", "info"))
    message = evt.get("message") or ""
    data = evt.get("data") or {}
    actor = data.get("actor")
    body_lines = [message] if message else []
    if actor:
        body_lines.append(f"actor: `{actor}`")
    for key in ("nodeName", "userName", "loginName", "hostname"):
        if data.get(key):
            body_lines.append(f"{key}: `{data[key]}`")
    body = "\n".join(body_lines) or f"`{event_type}`"
    return prefix, body, notify_type


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

        sig_header = self.headers.get("Tailscale-Webhook-Signature", "")
        parts = dict(p.split("=", 1) for p in sig_header.split(",") if "=" in p)
        ts_str, sig = parts.get("t"), parts.get("v1")
        if not ts_str or not sig:
            log(f"REJECTED missing/malformed signature header from {self.client_address[0]}")
            self.send_response(401)
            self.end_headers()
            return

        try:
            event_ts = int(ts_str)
        except ValueError:
            self.send_response(401)
            self.end_headers()
            return
        if abs(time.time() - event_ts) > MAX_CLOCK_SKEW_SECONDS:
            log(f"REJECTED stale timestamp ({ts_str}) from {self.client_address[0]}")
            self.send_response(401)
            self.end_headers()
            return

        signing_string = f"{ts_str}.".encode() + raw_body
        expected = hmac.new(WEBHOOK_SECRET, signing_string, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            log(f"REJECTED bad signature, {len(raw_body)} bytes from {self.client_address[0]}")
            self.send_response(401)
            self.end_headers()
            return

        try:
            events = json.loads(raw_body)
        except json.JSONDecodeError:
            log(f"REJECTED invalid JSON, {len(raw_body)} bytes")
            self.send_response(400)
            self.end_headers()
            return
        if not isinstance(events, list):
            events = [events]  # tolerate a single-object body even though docs say array

        for evt in events:
            title, body, notify_type = describe_event(evt)
            log(f"received type={evt.get('type')!r} -> title={title!r}")
            notify_data = urllib.parse.urlencode(
                {"title": title, "body": body, "type": notify_type, "format": "markdown"}
            ).encode()
            req = urllib.request.Request(APPRISE_NOTIFY_URL, data=notify_data, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    log(f"forwarded to Apprise, status={resp.status}")
            except urllib.error.URLError as e:
                log(f"APPRISE FORWARD FAILED: {e}")

        self.send_response(200)
        self.end_headers()

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
