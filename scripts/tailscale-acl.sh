#!/bin/sh
# Read and update the Tailscale tailnet policy file (ACL grants, SSH rules,
# tagOwners) via the API, in the same shape as ./dns-nextdns.sh.
#
# The API key is used only inside a Python process via urllib — never passed
# to curl or any other subprocess, so it never appears in argv. Tailscale
# authenticates with HTTP Basic using the key as the username and an empty
# password, so the header is built by hand here rather than shelling out.
#
# `put` always POSTs to /acl/validate first and refuses to apply a policy the
# API rejects — a malformed policy is applied atomically and can lock every
# device out of every resource, so a syntax error should fail here rather
# than in production. It also sends `If-Match` with the ETag read moments
# earlier, so a concurrent edit in the admin console is a 412 rather than a
# silent clobber.
#
# The policy is HuJSON (JSON plus comments and trailing commas). Round-trip
# it as bytes — do NOT parse and re-serialise it, or every comment in the
# file is destroyed.
#
# Usage:
#   ./scripts/tailscale-acl.sh get [outfile]   # default: stdout
#   ./scripts/tailscale-acl.sh put <file>
set -eu

ACTION="${1:?Usage: $0 get [outfile] | put <file>}"

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

PROTON_PASS_AGENT_REASON="Tailscale policy file: $ACTION $*" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "Tailscale" --output json \
    | ACTION="$ACTION" FILE_ARG="${2:-}" python3 -c '
import base64, json, os, sys, urllib.request, urllib.error

d = json.load(sys.stdin)
content = d["item"]["content"]
key = None
fields = [f for s in content["content"]["Custom"]["sections"] for f in s["section_fields"]]
# `pass-cli item update --field x=y` writes into a separate top-level
# `extra_fields` array, not into any section — see dns-nextdns.sh.
fields += content.get("extra_fields", [])
for f in fields:
    if f["name"] == "TAILSCALE_API_KEY":
        key = list(f["content"].values())[0]
if not key:
    sys.exit("No TAILSCALE_API_KEY field on the \"Tailscale\" item.")

AUTH = "Basic " + base64.b64encode(f"{key}:".encode()).decode()
BASE = "https://api.tailscale.com/api/v2/tailnet/-"


def call(method, path, body=None, ctype="application/hujson", extra=None):
    headers = {"Authorization": AUTH, "Accept": "application/hujson"}
    if body is not None:
        headers["Content-Type"] = ctype
    headers.update(extra or {})
    req = urllib.request.Request(BASE + path, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> HTTP {e.code}: {e.read().decode()}")


action = os.environ["ACTION"]
arg = os.environ.get("FILE_ARG") or ""

if action == "get":
    raw, _ = call("GET", "/acl")
    if arg:
        open(arg, "wb").write(raw)
        print(f"Wrote {len(raw)} bytes to {arg}")
    else:
        sys.stdout.write(raw.decode())

elif action == "put":
    if not arg:
        sys.exit("Usage: tailscale-acl.sh put <file>")
    new = open(arg, "rb").read()

    # Refuse to apply anything the API itself will not accept.
    call("POST", "/acl/validate", new)
    print("validate: OK")

    _, hdrs = call("GET", "/acl")
    etag = hdrs.get("ETag") or hdrs.get("Etag")
    if not etag:
        sys.exit("No ETag returned; refusing to apply without concurrency protection.")

    call("POST", "/acl", new, extra={"If-Match": etag})
    print(f"applied: {len(new)} bytes (If-Match {etag})")

else:
    sys.exit(f"Unknown action: {action}")
'
