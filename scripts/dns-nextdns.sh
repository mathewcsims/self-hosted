#!/bin/sh
# Manage NextDNS "rewrites" — the LAN split-DNS entries used throughout this
# repo so LAN clients resolve straight to the Pi instead of round-tripping
# out to the WAN IP and back. This is a real field in NextDNS's API
# (`GET /profiles/:profile` returns a `rewrites` array) even though it isn't
# mentioned in their public beta docs (https://nextdns.github.io/api/) —
# confirmed by testing directly against the live API rather than assuming
# either way.
#
# The API token is used only inside a Python process via urllib — never
# passed to curl or any other subprocess, so it never appears in argv.
#
# Usage:
#   ./scripts/dns-nextdns.sh list
#   ./scripts/dns-nextdns.sh add <hostname> <ip>
#   ./scripts/dns-nextdns.sh remove <hostname>
set -eu

ACTION="${1:?Usage: $0 list|add|remove ...}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

export PROTON_PASS_SESSION_DIR="${PROTON_PASS_SESSION_DIR:-/tmp/pass-agent-selfhosted}"
mkdir -p "$PROTON_PASS_SESSION_DIR"

if ! pass-cli info >/dev/null 2>&1; then
    if [ ! -f "$REPO_ROOT/.env" ]; then
        echo "No active pass-cli session, and no $REPO_ROOT/.env to auto-login with." >&2
        exit 1
    fi
    set -a
    . "$REPO_ROOT/.env"
    set +a
    export PROTON_PASS_PERSONAL_ACCESS_TOKEN="$SECRET_ACCESS_TOKEN"
    pass-cli login >/dev/null
    unset PROTON_PASS_PERSONAL_ACCESS_TOKEN SECRET_ACCESS_TOKEN
fi

PROTON_PASS_AGENT_REASON="NextDNS rewrite management: $ACTION $*" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "NextDNS" --output json \
    | ACTION="$ACTION" HOSTNAME_ARG="${2:-}" IP_ARG="${3:-}" python3 -c '
import json, os, sys, urllib.request, urllib.error

d = json.load(sys.stdin)
token = None
for s in d["item"]["content"]["content"]["Custom"]["sections"]:
    for f in s["section_fields"]:
        if f["name"] == "NEXT_DNS_TOKEN":
            token = list(f["content"].values())[0]

def call(method, path, body=None):
    url = f"https://api.nextdns.io{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "X-Api-Key": token,
        "Content-Type": "application/json",
        # NextDNS API sits behind Cloudflare, which returns a 403 (error
        # 1010) against the default urllib User-Agent -- a plain
        # identifying UA clears it, same as curl default already did in
        # manual testing.
        "User-Agent": "self-hosted-dns-script/1.0",
    })
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> HTTP {e.code}: {e.read().decode()}")

profiles = call("GET", "/profiles")["data"]
if len(profiles) != 1:
    sys.exit(f"Expected exactly one NextDNS profile, found {len(profiles)}: {profiles}")
profile_id = profiles[0]["id"]

action = os.environ["ACTION"]
hostname = os.environ.get("HOSTNAME_ARG", "")
ip = os.environ.get("IP_ARG", "")

if action == "list":
    rewrites = call("GET", f"/profiles/{profile_id}/rewrites")["data"]
    for r in rewrites:
        name, content, rtype, rid = r["name"], r["content"], r["type"], r["id"]
        print(f"{name} -> {content} ({rtype}, id={rid})")
elif action == "add":
    if not hostname or not ip:
        sys.exit("Usage: add <hostname> <ip>")
    call("POST", f"/profiles/{profile_id}/rewrites", {"name": hostname, "content": ip})
    print(f"Added rewrite: {hostname} -> {ip}")
elif action == "remove":
    if not hostname:
        sys.exit("Usage: remove <hostname>")
    rewrites = call("GET", f"/profiles/{profile_id}/rewrites")["data"]
    matches = [r for r in rewrites if r["name"] == hostname]
    if not matches:
        sys.exit(f"No rewrite found for {hostname}")
    for r in matches:
        rid = r["id"]
        call("DELETE", f"/profiles/{profile_id}/rewrites/{rid}")
        print(f"Removed rewrite: {hostname} (id={rid})")
else:
    sys.exit(f"Unknown action: {action}")
'
