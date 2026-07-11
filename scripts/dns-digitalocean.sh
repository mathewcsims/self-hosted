#!/bin/sh
# Manage DigitalOcean DNS records for mathewcsims.uk — the public A records
# every app in this repo needs for cert issuance (see each app's SETUP.md
# section). DigitalOcean's API uses the record's name RELATIVE to the zone
# (e.g. "cp", not "cp.mathewcsims.uk"; "@" for the bare apex) — confirmed
# directly against the live API, not assumed.
#
# The API token is used only inside a Python process via urllib — never
# passed to curl or any other subprocess, so it never appears in argv.
#
# Usage:
#   ./scripts/dns-digitalocean.sh list
#   ./scripts/dns-digitalocean.sh add <subdomain> <ip>
#   ./scripts/dns-digitalocean.sh remove <subdomain>
#   ./scripts/dns-digitalocean.sh add-caa <name> <tag> <value>   # tag: issue|issuewild|iodef
#   ./scripts/dns-digitalocean.sh list-caa
#   ./scripts/dns-digitalocean.sh remove-caa <name> <tag> <value>
set -eu

ACTION="${1:?Usage: $0 list|add|remove|add-caa|list-caa|remove-caa ...}"
DOMAIN="mathewcsims.uk"

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

PROTON_PASS_AGENT_REASON="DigitalOcean DNS management: $ACTION $*" \
    pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "Digital Ocean DNS" --output json \
    | ACTION="$ACTION" NAME_ARG="${2:-}" IP_ARG="${3:-}" TAG_ARG="${3:-}" VALUE_ARG="${4:-}" DOMAIN="$DOMAIN" python3 -c '
import json, os, sys, urllib.request, urllib.error, urllib.parse

d = json.load(sys.stdin)
token = None
for s in d["item"]["content"]["content"]["Custom"]["sections"]:
    for f in s["section_fields"]:
        if f["name"] == "DIGITAL_OCEAN_DNS_TOKEN":
            token = list(f["content"].values())[0]

domain = os.environ["DOMAIN"]

def call(method, path, body=None):
    url = f"https://api.digitalocean.com/v2{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> HTTP {e.code}: {e.read().decode()}")

action = os.environ["ACTION"]
name = os.environ.get("NAME_ARG", "")
ip = os.environ.get("IP_ARG", "")

if action == "list":
    records = call("GET", f"/domains/{domain}/records?per_page=200")["domain_records"]
    for r in records:
        if r["type"] == "A":
            rname, rdata, rid, rttl = r["name"], r["data"], r["id"], r["ttl"]
            print(f"{rname} -> {rdata} (id={rid}, ttl={rttl})")
elif action == "add":
    if not name or not ip:
        sys.exit("Usage: add <subdomain> <ip>")
    call("POST", f"/domains/{domain}/records", {"type": "A", "name": name, "data": ip, "ttl": 30})
    print(f"Added A record: {name}.{domain} -> {ip}")
elif action == "remove":
    if not name:
        sys.exit("Usage: remove <subdomain>")
    records = call("GET", f"/domains/{domain}/records?per_page=200")["domain_records"]
    matches = [r for r in records if r["type"] == "A" and r["name"] == name]
    if not matches:
        sys.exit(f"No A record found for {name}.{domain}")
    for r in matches:
        rid = r["id"]
        call("DELETE", f"/domains/{domain}/records/{rid}")
        print(f"Removed A record: {name}.{domain} (id={rid})")
elif action == "list-caa":
    records = call("GET", f"/domains/{domain}/records?per_page=200")["domain_records"]
    for r in records:
        if r["type"] == "CAA":
            rname, rflags, rtag, rdata, rid, rttl = r["name"], r["flags"], r["tag"], r["data"], r["id"], r["ttl"]
            print(f"{rname} CAA {rflags} {rtag} \"{rdata}\" (id={rid}, ttl={rttl})")
elif action == "add-caa":
    tag = os.environ.get("TAG_ARG", "")
    value = os.environ.get("VALUE_ARG", "")
    if not name or tag not in ("issue", "issuewild", "iodef") or not value:
        sys.exit("Usage: add-caa <name> <issue|issuewild|iodef> <value>")
    call("POST", f"/domains/{domain}/records", {
        "type": "CAA", "name": name, "flags": 0, "tag": tag, "data": value, "ttl": 1800,
    })
    print(f"Added CAA record: {name}.{domain} {tag} \"{value}\"")
elif action == "remove-caa":
    tag = os.environ.get("TAG_ARG", "")
    value = os.environ.get("VALUE_ARG", "")
    if not name or not tag or not value:
        sys.exit("Usage: remove-caa <name> <tag> <value>")
    records = call("GET", f"/domains/{domain}/records?per_page=200")["domain_records"]
    matches = [r for r in records if r["type"] == "CAA" and r["name"] == name and r["tag"] == tag and r["data"] == value]
    if not matches:
        sys.exit(f"No matching CAA record found for {name}.{domain} {tag} \"{value}\"")
    for r in matches:
        rid = r["id"]
        call("DELETE", f"/domains/{domain}/records/{rid}")
        print(f"Removed CAA record: {name}.{domain} {tag} \"{value}\" (id={rid})")
else:
    sys.exit(f"Unknown action: {action}")
'
