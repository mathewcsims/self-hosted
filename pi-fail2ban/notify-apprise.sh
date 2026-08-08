#!/bin/sh
# Invoked by fail2ban's actionban/actionunban hooks. Posts to the shared
# Apprise container the same way every other notifier in this repo does.
# Reachable because the Pi itself, as the source, satisfies Caddy's own
# private_ranges/Tailscale-CGNAT gate on apprise.mathewcsims.uk (live-
# verified: curl https://apprise.mathewcsims.uk/ from this host returns
# 200). Best-effort, no retry — a failed notify must never block the ban,
# which has already happened by the time this runs.
#
# NOTE the endpoint is /notify/fail2ban, NOT the /notify/self-hosted key
# everything else in this repo uses. The caddy-abuse jail bans at a rate no
# human wants interleaved with real alerts (119 lifetime bans, 54 concurrent,
# as of 2026-08-08), so this route now goes to a dedicated ntfy topic
# ("fail2ban", priority=low) and is deliberately NOT delivered to Discord at
# all. Both the topic and the priority live on the Apprise-side
# target URL — see ../scripts/pass-seed-apprise.sh — so nothing about this
# script changes if either is retuned.

ACTION="$1"
JAIL="$2"
IP="$3"

if [ "$ACTION" = "ban" ]; then
    TITLE="🚫 fail2ban: banned an IP"
    TYPE="failure"
    BODY="**Jail:** \`${JAIL}\`
**IP:** \`${IP}\`
**Host:** babel"
else
    TITLE="✅ fail2ban: unbanned an IP"
    TYPE="success"
    BODY="**Jail:** \`${JAIL}\`
**IP:** \`${IP}\`
**Host:** babel"
fi

curl -fsS --max-time 10 \
    --data-urlencode "title=${TITLE}" \
    --data-urlencode "type=${TYPE}" \
    --data-urlencode "format=markdown" \
    --data-urlencode "body=${BODY}" \
    https://apprise.mathewcsims.uk/notify/fail2ban >/dev/null 2>&1 || true
