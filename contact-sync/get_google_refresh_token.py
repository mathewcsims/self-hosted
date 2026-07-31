#!/usr/bin/env python3
"""Mint a fresh Google refresh token for contact-sync, via the OAuth
loopback flow.

── WHY THIS EXISTS ───────────────────────────────────────────────────────
The contact-sync Google credential is an OAuth **Desktop app** client, and
desktop clients authenticate through a loopback redirect
(http://127.0.0.1:<port>) — they cannot use a registered redirect URI at
all. That matters because the obvious alternative, Google's OAuth
Playground, returns `Error 400: redirect_uri_mismatch` against a desktop
client and there is no setting that makes it work.

This flow was used to create the original token in July 2026 but was never
committed, so when the token expired on 2026-07-27 the method had to be
rediscovered — and was briefly got wrong. Committing it makes
re-authorisation a repeatable two-minute job instead of a research task.

── WHEN YOU NEED THIS ────────────────────────────────────────────────────
When a sync run reports:

    google: PULL FAILED (Google refresh token is expired or revoked …)

That error never self-heals. Note the underlying cause: if the OAuth app's
publishing status is still "Testing", Google expires refresh tokens after
**7 days**, so this will recur weekly until it is set to "In production"
(console.cloud.google.com/auth/audience). Publishing does not require
verification for a single user accessing their own data — you just accept
an "unverified app" interstitial during sign-in.

── WHAT IT DOES NOT DO ───────────────────────────────────────────────────
It does NOT write the token to Proton Pass. The agent's Pass token is
read-only, and more importantly a credential this sensitive should be
placed by hand rather than by a script. The token is printed once, to your
terminal, for you to copy across.

Usage — nothing to install, no arguments:

    python3 contact-sync/get_google_refresh_token.py

It reads GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET from the "Contact Sync
Google" Pass item itself, so there is nothing to paste in beforehand.
"""

import base64
import hashlib
import http.server
import json
import os
import secrets
import socket
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

VAULT = "Self-Hosted Secrets"
ITEM = "Contact Sync Google"
SCOPE = "https://www.googleapis.com/auth/contacts"
AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"


def pass_field(name):
    """Same read path as run-sync.sh — both Custom.sections and
    extra_fields, since which one a field lands in depends on how it was
    added."""
    out = subprocess.run(
        ["pass-cli", "item", "view", "--vault-name", VAULT,
         "--item-title", ITEM, "--output", "json"],
        capture_output=True, text=True,
        env={**os.environ,
             "PROTON_PASS_AGENT_REASON": "minting a new Google refresh token"},
    )
    if out.returncode != 0:
        sys.exit(f"pass-cli failed — is the session authenticated?\n{out.stderr}")
    d = json.loads(out.stdout)
    content = d["item"]["content"]["content"]
    fields = [f for s in content["Custom"]["sections"] for f in s["section_fields"]]
    fields += d["item"]["content"].get("extra_fields", [])
    for f in fields:
        if f["name"] == name:
            return list(f["content"].values())[0]
    sys.exit(f"field {name} not found in Pass item {ITEM!r}")


def free_port():
    """Bind :0 and let the OS choose. Desktop OAuth clients accept ANY
    loopback port, so there is nothing to pre-register — which is exactly
    what makes this flow work where the Playground cannot."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Handler(http.server.BaseHTTPRequestHandler):
    code = None
    error = None

    def do_GET(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        Handler.code = params.get("code", [None])[0]
        Handler.error = params.get("error", [None])[0]
        body = (b"<h2>Authorised.</h2><p>Return to your terminal.</p>"
                if Handler.code else
                b"<h2>Authorisation failed.</h2><p>Return to your terminal.</p>")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # the access log is noise here


def main():
    client_id = pass_field("GOOGLE_CLIENT_ID")
    client_secret = pass_field("GOOGLE_CLIENT_SECRET")

    # PKCE. Google does not require it for desktop clients that also send a
    # client secret, but it costs nothing and closes the interception
    # window on the loopback redirect, which is plain HTTP.
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(64)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)

    port = free_port()
    redirect_uri = f"http://127.0.0.1:{port}"

    url = AUTH_ENDPOINT + "?" + urllib.parse.urlencode({
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": SCOPE,
        # Both are required to get a refresh token back: Google only issues
        # one on the FIRST consent unless you force the prompt.
        "access_type": "offline",
        "prompt": "consent",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    })

    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.handle_request, daemon=True).start()

    print(f"\nOpening your browser to authorise (listening on {redirect_uri}).")
    print("If it doesn't open, paste this into a browser yourself:\n")
    print(url + "\n")
    print("You may see an 'unverified app' warning — that is expected for a")
    print("single-user app. Choose Advanced, then 'Go to ... (unsafe)'.\n")
    webbrowser.open(url)

    server.socket.settimeout(300)
    while Handler.code is None and Handler.error is None:
        threading.Event().wait(0.2)

    if Handler.error:
        sys.exit(f"authorisation failed: {Handler.error}")

    body = urllib.parse.urlencode({
        "client_id": client_id,
        "client_secret": client_secret,
        "code": Handler.code,
        "code_verifier": verifier,
        "grant_type": "authorization_code",
        "redirect_uri": redirect_uri,
    }).encode()
    try:
        with urllib.request.urlopen(
                urllib.request.Request(TOKEN_ENDPOINT, data=body, method="POST"),
                timeout=30) as r:
            tok = json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"token exchange failed ({e.code}): {e.read().decode()[:500]}")

    if "refresh_token" not in tok:
        sys.exit("no refresh_token returned — Google only issues one with "
                 "access_type=offline AND prompt=consent; check both are set")

    print("=" * 68)
    print("New refresh token (copy it into Pass now — it is not saved here):\n")
    print(tok["refresh_token"])
    print()
    print(f"  Vault: {VAULT}")
    print(f"  Item:  {ITEM}")
    print("  Field: GOOGLE_REFRESH_TOKEN")
    print()
    print(f"Granted scopes: {tok.get('scope')}")
    print("=" * 68)


if __name__ == "__main__":
    main()
