#!/bin/sh
# Invoked by fail2ban's actionban/actionunban hooks. Posts to the shared
# Apprise container the same way every other notifier in this repo does.
# Reachable because the Pi itself, as the source, satisfies Caddy's own
# private_ranges/Tailscale-CGNAT gate on apprise.mathewcsims.uk (live-
# verified: curl https://apprise.mathewcsims.uk/ from this host returns
# 200). Best-effort, no retry — a failed notify must never block the ban,
# which has already happened by the time this runs.

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
    https://apprise.mathewcsims.uk/notify/self-hosted >/dev/null 2>&1 || true
