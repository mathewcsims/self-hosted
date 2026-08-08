#!/bin/sh
# Invoked by fail2ban's actionban/actionunban hooks. Posts to the shared
# Apprise container the same way every other notifier in this repo does.
# Reachable because the Pi itself, as the source, satisfies Caddy's own
# private_ranges/Tailscale-CGNAT gate on apprise.mathewcsims.uk (live-
# verified: curl https://apprise.mathewcsims.uk/ from this host returns
# 200). Best-effort, no retry — a failed notify must never block the ban,
# which has already happened by the time this runs.
#
# NOTE this does NOT post to /notify/self-hosted like everything else in this
# repo. Bans are split across two Apprise config keys by jail, because the two
# jails here are nothing alike in either volume or seriousness:
#
#   caddy-abuse    -> /notify/fail2ban          ntfy topic "fail2ban",
#       priority low, no Discord. Internet background radiation: ~10 bans a
#       day even after the 2026-08-08 retuning, and ~67 before it. Worth
#       logging, not worth a buzz.
#
#   anything else  -> /notify/fail2ban-urgent   Discord + ntfy topic
#       "alerts" at priority high. sshd lives here: it has fired ZERO times
#       in its lifetime, and password auth is off (../pi-sshd/), so a ban
#       means something is attempting SSH auth that should not be — rare,
#       and worth interrupting for.
#
# Unknown jails default to the urgent route on purpose: a jail added later
# should be loud until somebody deliberately decides it is noise, rather
# than silently going missing. Topics and priorities live on the
# Apprise-side target URLs (../scripts/pass-seed-apprise.sh), so retuning
# either needs no change here.

ACTION="$1"
JAIL="$2"
IP="$3"

case "$JAIL" in
    caddy-abuse) KEY="fail2ban" ;;
    *)           KEY="fail2ban-urgent" ;;
esac

if [ "$ACTION" = "ban" ]; then
    TYPE="failure"
    if [ "$KEY" = "fail2ban" ]; then
        TITLE="🚫 fail2ban: banned an IP"
    else
        TITLE="🚨 fail2ban: ${JAIL} ban on babel"
    fi
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
    "https://apprise.mathewcsims.uk/notify/${KEY}" >/dev/null 2>&1 || true
