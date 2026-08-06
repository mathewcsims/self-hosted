#!/bin/sh
# Watches the two things that can silently break LiteLLM, and tells you via
# Apprise -> ntfy/Discord when one does.
#
# WHY THIS EXISTS: the ADC credential is a *user* refresh token, not a service
# account (employer policy blocks downloadable SA keys). Google's reauth
# policy expires it — observed lasting **four days**, 2026-08-02 to 08-06.
# When it goes, LiteLLM itself stays perfectly healthy: the container is up,
# /health/liveliness returns 200, the tailnet sidecar is fine. Only the
# upstream credential is dead, so every completion 500s with a
# `RefreshError: Reauthentication is needed`. Nothing else in the estate
# notices, and the first sign is a stack trace in whatever client you happen
# to use next — which is how it was found the first time.
#
# So this checks the CREDENTIAL, not just the service. `gcloud auth
# application-default print-access-token` exits non-zero the moment the
# refresh token needs reauthenticating, which makes it a precise leading
# indicator with no secrets required.
#
# Deliberately needs NO LiteLLM API key: the liveliness endpoint is
# unauthenticated, and the ADC check runs as the user that owns the
# credential. Nothing secret is read, stored, or transmitted by this script.
#
# Install (on slartibartfast, same pattern as kopia-immich.*):
#   cp litellm/adc-check.sh ~/litellm/adc-check.sh && chmod +x ~/litellm/adc-check.sh
#   cp litellm/litellm-adc-check.{service,timer} ~/.config/systemd/user/
#   systemctl --user daemon-reload
#   systemctl --user enable --now litellm-adc-check.timer
set -u

# Overridable so the failure path can be exercised without breaking the real
# credential — see the verification note in SETUP.md.
GCLOUD="${GCLOUD:-$HOME/google-cloud-sdk/bin/gcloud}"
APPRISE="https://apprise.mathewcsims.uk/notify/self-hosted"
LIVENESS="https://litellm.possum-prometheus.ts.net/health/liveliness"
# Runtime state lives outside the repo — same tracked-script/untracked-data
# split as contact-sync/ and trivy-scan/.
STATE="$HOME/.litellm-adc-monitor-state"
# While still broken, re-nag at most once a day rather than every run —
# matches the resend-only-on-change spirit of the rest of this repo's
# notifications, without letting a real outage go quiet forever.
RENAG_SECONDS=86400

notify() {
    # $1 = title, $2 = body, $3 = type (failure|success)
    curl -s -o /dev/null -m 20 -X POST "$APPRISE" \
        --data-urlencode "title=$1" \
        --data-urlencode "body=$2" \
        --data-urlencode "type=$3" \
        --data-urlencode "format=markdown" || true
}

# ── the checks ────────────────────────────────────────────────────────────
FAIL=""

if ! "$GCLOUD" auth application-default print-access-token >/dev/null 2>&1; then
    FAIL="adc"
elif ! curl -s -o /dev/null -m 25 -f "$LIVENESS"; then
    # Only checked when ADC is healthy, so the alert names one cause, not two.
    FAIL="proxy"
fi

# ── state transitions ─────────────────────────────────────────────────────
PREV_STATE=""
PREV_AT=0
if [ -f "$STATE" ]; then
    PREV_STATE=$(cut -d' ' -f1 <"$STATE" 2>/dev/null)
    PREV_AT=$(cut -d' ' -f2 <"$STATE" 2>/dev/null)
    [ -n "$PREV_AT" ] || PREV_AT=0
fi
NOW=$(date +%s)

if [ -z "$FAIL" ]; then
    if [ "$PREV_STATE" != "ok" ] && [ -n "$PREV_STATE" ]; then
        notify "LiteLLM recovered" \
"LiteLLM is answering again — the credential and the proxy are both healthy.

No action needed." "success"
    fi
    echo "ok $NOW" >"$STATE"
    echo "ok"
    exit 0
fi

# Notify on entering failure, or once a day while it persists.
SHOULD_NOTIFY=0
[ "$PREV_STATE" != "$FAIL" ] && SHOULD_NOTIFY=1
[ "$PREV_STATE" = "$FAIL" ] && [ $((NOW - PREV_AT)) -ge "$RENAG_SECONDS" ] && SHOULD_NOTIFY=1

if [ "$SHOULD_NOTIFY" -eq 1 ]; then
    if [ "$FAIL" = "adc" ]; then
        notify "LiteLLM: GCP credential needs reauthenticating" \
"The Application Default Credential on slartibartfast has expired, so every
LiteLLM request will fail with a 500 (\`Reauthentication is needed\`).

**LiteLLM itself is fine** — the container, the tailnet sidecar and the
proxy are all healthy. Only the upstream credential is dead.

Fix (only you can do this — it authenticates as your Google account):

\`\`\`
ssh mathewcsims@100.68.10.65 '~/google-cloud-sdk/bin/gcloud auth application-default login --no-launch-browser'
\`\`\`

No restart needed afterwards; LiteLLM reads the credential per request.

This recurs roughly every few days under your employer's session policy —
see SETUP.md for why, and the Workload Identity Federation alternative." "failure"
    else
        notify "LiteLLM: proxy not responding" \
"The GCP credential is healthy, but \`${LIVENESS}\` did not return 200.

That points at the container or the Tailscale sidecar on slartibartfast
rather than at the credential. Check:

\`\`\`
ssh mathewcsims@100.68.10.65 'docker ps --filter name=litellm; docker logs --tail 40 litellm-app'
\`\`\`" "failure"
    fi
    echo "$FAIL $NOW" >"$STATE"
else
    # Preserve the timestamp of the last notification so the daily re-nag
    # measures from when we last told you, not from the last check.
    echo "$FAIL $PREV_AT" >"$STATE"
fi

echo "$FAIL"
exit 1
