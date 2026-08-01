#!/bin/sh
# Creates Donetick's single account, then closes registration again.
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────
# Donetick has NO CLI or env-var way to seed the first account — the only
# route in is the public signup form. The previous deployment (eecb9cb)
# solved that by leaving registration permanently open, mirroring Memos.
# This instance is public, so it ships CLOSED instead
# (DT_IS_USER_CREATION_DISABLED=true) and this script opens the window for
# a few seconds only.
#
# The flow:
#   1. redeploy with registration temporarily ENABLED
#   2. POST the one account, credentials straight from Proton Pass
#   3. redeploy with registration CLOSED again
#   4. verify signup is actually refused afterwards
#
# Step 4 matters: without it you are trusting that step 3 took effect, and
# an open signup form on a public hostname is exactly the thing this is
# meant to avoid.
#
# The password never reaches argv — it goes into the JSON body inside a
# python process, same reasoning as every other secret handled here.
#
# Usage (from the repo root, with a pass-cli session active):
#   ./scripts/bootstrap-donetick-account.sh
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSH_HOST="mathewcsims@100.68.10.65"
REMOTE_PATH='~/donetick'
BASE="https://donetick.mathewcsims.uk"

# ── CLOSE REGISTRATION NO MATTER HOW WE EXIT ──────────────────────────────
# `set -e` plus a failure in step 2 originally left the instance running
# with signup OPEN on a public hostname — the precise outcome this script
# exists to prevent. It happened for real on 2026-08-01 when the account
# payload was rejected (username under Donetick's 4-character minimum) and
# the script died before step 3.
#
# This trap runs on ANY exit — success, error, or interrupt — removes the
# override and redeploys closed. It is deliberately best-effort and silent
# about its own failures, because the alternative to a messy close is no
# close at all.
cleanup() {
    _rc=$?
    if ssh "$SSH_HOST" "test -f $REMOTE_PATH/compose.override.yaml" 2>/dev/null; then
        echo "!! exiting with registration still open — closing it now"
        ssh "$SSH_HOST" "rm -f $REMOTE_PATH/compose.override.yaml" 2>/dev/null || true
        "$REPO_ROOT/scripts/pass-deploy-remote.sh" donetick "$SSH_HOST" "$REMOTE_PATH" >/dev/null 2>&1 || true
        echo "   registration closed (verify with a POST to $BASE/api/v1/auth/)"
    fi
    exit $_rc
}
trap cleanup EXIT INT TERM

# The toggle is applied with a TRANSIENT compose.override.yaml on the remote
# rather than an env var. pass-deploy-remote.sh only exports fields it read
# from Proton Pass, so an env var set here would never reach the host — and
# hardcoding the flag in compose.yaml is deliberate, so that the committed
# file is closed-by-default no matter how it is deployed. Docker Compose
# picks up compose.override.yaml automatically; deleting it reverts.
echo "==> 1/4  opening registration temporarily"
ssh "$SSH_HOST" "cat > $REMOTE_PATH/compose.override.yaml" <<'OVERRIDE'
# TRANSIENT — written by scripts/bootstrap-donetick-account.sh and deleted
# again moments later. If you find this file lying around, the bootstrap
# failed part-way and registration may still be OPEN. Delete it and redeploy.
services:
  donetick:
    environment:
      DT_IS_USER_CREATION_DISABLED: "false"
OVERRIDE
"$REPO_ROOT/scripts/pass-deploy-remote.sh" donetick "$SSH_HOST" "$REMOTE_PATH" >/dev/null
# Give the app time to come back up before posting at it.
until curl -fsS -o /dev/null --max-time 5 "$BASE/" 2>/dev/null; do sleep 2; done

echo "==> 2/4  creating the account"
PROTON_PASS_AGENT_REASON="bootstrapping the Donetick account" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "Donetick" --output json \
    | python3 -c '
import json, sys, urllib.request, urllib.error

d = json.load(sys.stdin)
content = d["item"]["content"]["content"]
fields = {f["name"]: list(f["content"].values())[0]
          for s in content["Custom"]["sections"] for f in s["section_fields"]}
fields.update({f["name"]: list(f["content"].values())[0]
               for f in d["item"]["content"].get("extra_fields", [])})

body = json.dumps({
    "username": fields["DONETICK_USERNAME"],
    "password": fields["DONETICK_PASSWORD"],
    "email": fields["DONETICK_EMAIL"],
    "displayName": "Mathew",
}).encode()

req = urllib.request.Request(sys.argv[1] + "/api/v1/auth/", data=body,
                             method="POST",
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        print(f"   account created (HTTP {r.status})")
except urllib.error.HTTPError as e:
    detail = e.read().decode()[:200]
    # Already existing is fine — this script is safe to re-run.
    if e.code in (400, 409) and "exist" in detail.lower():
        print("   account already exists — continuing")
    else:
        sys.exit(f"   signup FAILED ({e.code}): {detail}")
' "$BASE"

echo "==> 3/4  closing registration again"
ssh "$SSH_HOST" "rm -f $REMOTE_PATH/compose.override.yaml"
"$REPO_ROOT/scripts/pass-deploy-remote.sh" donetick "$SSH_HOST" "$REMOTE_PATH" >/dev/null
until curl -fsS -o /dev/null --max-time 5 "$BASE/" 2>/dev/null; do sleep 2; done

# The endpoint is POST /api/v1/auth/ — a bare slash on the auth group, NOT
# /api/v1/auth/signup. Donetick serves its own SPA, so ANY unmatched path
# returns index.html with HTTP 200; probing the wrong path looks exactly
# like a wide-open signup form. Got this wrong once already.
echo "==> 4/4  verifying registration is refused"
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
    -H 'Content-Type: application/json' \
    --data '{"username":"probe-should-fail","password":"probeprobe123","email":"probe@example.invalid"}' \
    "$BASE/api/v1/auth/" 2>/dev/null || true)
if [ "$CODE" = "403" ]; then
    echo "    signup correctly refused (HTTP 403) — registration is closed"
else
    echo "    !! signup returned HTTP $CODE, expected 403 — REGISTRATION MAY BE OPEN"
    exit 1
fi
