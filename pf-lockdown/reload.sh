#!/bin/sh
# Idempotent — safe to run at boot or interactively. Enables pf only if it
# isn't already (some other macOS component, like Internet Sharing, may
# have already turned it on — don't disturb that), then reloads the main
# ruleset, which pulls in the com.mathewcsims.lan-lockdown anchor.
#
# Run as root (this is what the LaunchDaemon does at boot).
#
# ── WHY THIS SCRIPT VERIFIES RATHER THAN ASSUMES ──────────────────────────
#
# `pfctl -f /etc/pf.conf` succeeds whether or not /etc/pf.conf still
# references our anchor. That is not a hypothetical: a macOS update replaced
# /etc/pf.conf with Apple's stock version, silently dropping the two lines
# from pf-conf-snippet.txt, and this script went on reporting success at
# every boot for weeks while enforcing NOTHING. copyparty's published port
# was reachable from any device on the LAN that whole time, not just the Pi.
# Found 2026-08-08, by accident, while narrowing the ruleset for something
# unrelated — `pfctl -s Anchors` listed only `com.apple`.
#
# The old version of this script could not have caught that, because
# exit status was the only thing it looked at. So it now:
#
#   1. re-adds the anchor lines to /etc/pf.conf if they have gone missing
#      (idempotent — guarded by a grep, so repeated runs cannot duplicate
#      them), because self-healing at boot beats waiting for someone to
#      notice;
#   2. asserts afterwards that the anchor is actually present in the kernel
#      AND non-empty — `pfctl -a <anchor> -s rules` exits 0 with no output
#      for an anchor that exists but holds nothing, so a rule COUNT is the
#      check, not exit status;
#   3. shouts via Apprise either way. A repair is still a warning: something
#      overwrote a system file, and you want to know that happened even
#      though it fixed itself.
#
# The failure mode this exists to prevent is a script that reports success
# while enforcing nothing — the same class of silent lie that
# scripts/dump-databases.sh goes to considerable lengths to avoid.

ANCHOR="com.mathewcsims.lan-lockdown"
ANCHOR_FILE="/etc/pf.anchors/$ANCHOR"
PF_CONF="/etc/pf.conf"
APPRISE_URL="https://apprise.mathewcsims.uk/notify/self-hosted"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Best-effort, never fatal — the lockdown's correctness must not depend on
# the Pi being up. Same pattern as kopia-mac/backup.sh.
notify() {
    _title=$1
    _type=$2
    _body=$3
    curl -fsS --max-time 10 \
        --data-urlencode "title=$_title" \
        --data-urlencode "type=$_type" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=$_body

Host: mathews-mac" \
        "$APPRISE_URL" >/dev/null 2>&1 || true
}

log "=== pf lockdown reload ==="

if [ ! -f "$ANCHOR_FILE" ]; then
    log "FATAL: $ANCHOR_FILE is missing"
    notify "🔴 pf lockdown BROKEN — anchor file missing" "failure" \
"\`$ANCHOR_FILE\` does not exist, so there is nothing to load and **the LAN
lockdown is not in effect**. copyparty's published port is reachable from any
device on the LAN, not just the Pi.

Restore it from the repo:

    sudo cp ~/self-hosted/pf-lockdown/$ANCHOR /etc/pf.anchors/$ANCHOR
    sudo /bin/sh ~/self-hosted/pf-lockdown/reload.sh"
    exit 1
fi

# 1. Self-heal /etc/pf.conf if a system update has stripped the anchor lines.
REPAIRED=0
if ! grep -q "$ANCHOR" "$PF_CONF" 2>/dev/null; then
    log "WARNING: $PF_CONF does not reference $ANCHOR — re-adding"
    printf '\nanchor "%s"\nload anchor "%s" from "%s"\n' \
        "$ANCHOR" "$ANCHOR" "$ANCHOR_FILE" >> "$PF_CONF"
    REPAIRED=1
fi

# 2. Enable pf only if something else hasn't already.
if ! /sbin/pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
    log "pf was disabled — enabling"
    /sbin/pfctl -e 2>&1
fi

/sbin/pfctl -f "$PF_CONF" 2>&1

# 3. Verify the anchor is in the kernel and actually holds rules. An anchor
#    that exists but is empty exits 0 here with no output, which is why the
#    test is on the line count and not on $?.
RULE_COUNT=$(/sbin/pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -c .)

if [ "$RULE_COUNT" -lt 1 ]; then
    log "FATAL: anchor $ANCHOR loaded 0 rules — lockdown is NOT in effect"
    notify "🔴 pf lockdown BROKEN — anchor loaded no rules" "failure" \
"\`pfctl -f $PF_CONF\` succeeded, but \`$ANCHOR\` holds **no rules**, so the
LAN lockdown is **not in effect** — copyparty's published port is reachable
from any device on the LAN, not just the Pi.

Check whether the anchor is loaded at all:

    sudo pfctl -s Anchors
    sudo pfctl -a $ANCHOR -s rules

See SETUP.md's \"Restricting LAN-only ports\" section."
    exit 1
fi

log "anchor $ANCHOR loaded, $RULE_COUNT rules"

if [ "$REPAIRED" -eq 1 ]; then
    log "NOTE: $PF_CONF had been overwritten and was repaired"
    notify "⚠️ pf lockdown was silently off — repaired" "warning" \
"\`$PF_CONF\` no longer referenced \`$ANCHOR\` — almost certainly a macOS
update replacing it with Apple's stock file. **The LAN lockdown had stopped
being enforced**, with no error from anything, until this run.

It has been repaired automatically and the anchor now loads $RULE_COUNT rules.
No action needed, but worth knowing an OS update did this — it will do it
again."
fi

log "=== done ==="
