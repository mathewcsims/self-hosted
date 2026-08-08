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

# The repo copy, alongside this script — the source of truth for the rules.
REPO_ANCHOR="$(cd "$(dirname "$0")" && pwd)/$ANCHOR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Never fatal — the lockdown's correctness must not depend on the Pi being
# up. Same pattern as kopia-mac/backup.sh, but with a retry loop, which that
# script does not need and this one does.
#
# WHY THE RETRY. This runs from a LaunchDaemon with RunAtLoad, so it starts
# EARLY — quite possibly before networking is up enough to resolve and reach
# apprise.mathewcsims.uk on the Pi. A single `curl ... || true` would then
# fail and be swallowed by design, and the one case this whole script exists
# to report — "an OS update silently disabled your firewall, and I fixed it"
# — would arrive nowhere. The repair itself is purely local and unaffected;
# it is only the telling that races the boot.
#
# So: keep trying for ~2.5 minutes, then give up and say so IN THE LOG. A
# notification that quietly fails to send is the same category of problem as
# a check that quietly passes, and this script is supposed to be the cure for
# that, not another instance of it.
NOTIFY_DEADLINE_SECS=150
NOTIFY_RETRY_SECS=10

notify() {
    _title=$1
    _type=$2
    _body=$3
    _deadline=$(( $(date +%s) + NOTIFY_DEADLINE_SECS ))
    _attempt=0

    while :; do
        _attempt=$(( _attempt + 1 ))
        if curl -fsS --max-time 10 \
            --data-urlencode "title=$_title" \
            --data-urlencode "type=$_type" \
            --data-urlencode "format=markdown" \
            --data-urlencode "body=$_body

Host: mathews-mac" \
            "$APPRISE_URL" >/dev/null 2>&1; then
            log "notification delivered on attempt $_attempt"
            return 0
        fi
        if [ "$(date +%s)" -ge "$_deadline" ]; then
            break
        fi
        log "notification attempt $_attempt failed (network may still be coming up) — retrying in ${NOTIFY_RETRY_SECS}s"
        sleep "$NOTIFY_RETRY_SECS"
    done

    log "WARNING: notification NOT delivered after $_attempt attempts over ${NOTIFY_DEADLINE_SECS}s — the message above is in this log only"
    return 1
}

log "=== pf lockdown reload ==="

# 0. Install the repo's anchor if the live one differs.
#
#    WHY THIS EXISTS. Editing pf-lockdown/<anchor> in the repo and running
#    this script did NOT previously apply the change: reload.sh only ever
#    reloaded /etc/pf.conf, and the anchor itself had to be copied to
#    /etc/pf.anchors/ by hand as a separate step. That is a step easy to
#    forget and impossible to notice, because the reload succeeds and
#    reports success either way.
#
#    It was forgotten on 2026-08-08, adding ports 3600 and 3601 for Fizzy and
#    Super Productivity. Both stayed reachable from every device on the LAN
#    while the repo, the commit and the docs all said otherwise — and Super
#    Productivity has no login at all, so for that app the rule was the only
#    access control there was.
#
#    The repo is the source of truth, exactly as it is for the Pi's Caddyfile.
#    Anything that edits the live file by hand will now be overwritten on the
#    next run, which is the intended direction.
if [ ! -f "$REPO_ANCHOR" ]; then
    log "FATAL: $REPO_ANCHOR is missing — cannot verify or install the ruleset"
    notify "🔴 pf lockdown BROKEN — repo anchor missing" "failure" \
"\`$REPO_ANCHOR\` does not exist, so this script cannot tell whether the live
ruleset is current. Check the repo is present and intact at that path."
    exit 1
fi

if ! cmp -s "$REPO_ANCHOR" "$ANCHOR_FILE" 2>/dev/null; then
    log "live anchor differs from the repo — installing $REPO_ANCHOR"
    install -o root -g wheel -m 644 "$REPO_ANCHOR" "$ANCHOR_FILE"
    ANCHOR_UPDATED=1
else
    ANCHOR_UPDATED=0
fi

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
#
#    Guarded on the file EXISTING first. `>>` would happily create it, and a
#    /etc/pf.conf containing only our two lines would drop Apple's own
#    scrub/nat/rdr/dummynet anchors — quietly changing system networking
#    behaviour to fix a firewall rule. Not a trade worth making automatically;
#    if the file is gone, something is wrong enough to want a human.
REPAIRED=0
if [ ! -f "$PF_CONF" ]; then
    log "FATAL: $PF_CONF does not exist — refusing to create it"
    notify "🔴 pf lockdown BROKEN — /etc/pf.conf is missing" "failure" \
"\`$PF_CONF\` does not exist. Not recreating it automatically: a pf.conf
holding only our anchor lines would drop Apple's own scrub/nat/rdr anchors.

Restore it from a Time Machine backup or another Mac, then re-append the
snippet:

    cat ~/self-hosted/pf-lockdown/pf-conf-snippet.txt | sudo tee -a $PF_CONF
    sudo /bin/sh ~/self-hosted/pf-lockdown/reload.sh"
    exit 1
fi

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
#    test is on the rule count and not on $?.
#
#    Count only RULE-SHAPED lines, not every non-empty line. pfctl prints
#    "No ALTQ support in kernel" / "ALTQ related functions disabled" on every
#    invocation on macOS, and while those appear to go to stderr, a plain
#    `grep -c .` would report 2 for a completely empty anchor if they ever
#    went to stdout instead — i.e. it would pass while enforcing nothing,
#    which is the exact failure this check exists to catch. Matching the
#    rule verbs removes the dependency on that assumption entirely.
RULE_COUNT=$(/sbin/pfctl -a "$ANCHOR" -s rules 2>/dev/null \
    | grep -cE '^[[:space:]]*(pass|block|match|scrub|nat|rdr|anchor)[[:space:]]')

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

if [ "$ANCHOR_UPDATED" -eq 1 ]; then
    log "NOTE: the live anchor was out of date and has been updated from the repo"
fi

log "=== done ==="
