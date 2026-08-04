#!/bin/sh
# Backs up slartibartfast's irreplaceable data — Immich's, and LiteLLM's —
# to the same Backblaze B2 Kopia repository the Mac and Pi use. Triggered
# daily by kopia-immich.timer (03:00) — see SETUP.md's Immich section.
#
# The unit is still called kopia-immich for historical reasons: Immich was
# the only thing on this host when it was written. It now covers everything
# on the box that is worth keeping. Renaming a working systemd unit on a
# remote machine buys nothing but risk, so the name stays and this note
# explains it.
#
# Runs as the `mathewcsims` USER, not root, via a systemd --user unit
# (linger is enabled so it fires without an active login). That works
# because Immich's container-written data directories are root-owned but
# world-readable. If Immich ever starts writing mode-600 files, kopia will
# report errors rather than silently skipping them — which is exactly why
# this script inspects kopia's exit status per source and alerts instead of
# reporting a cheerful success.
#
# WHY 03:00: Immich's own database backup runs at 02:00 (Admin ▸ Settings ▸
# Backup) and writes dumps into data/backups/. Snapshotting an hour later
# means every snapshot contains that night's fresh dump. Don't move this
# earlier than Immich's dump without moving Immich's too.
#
# WHAT IS DELIBERATELY NOT BACKED UP:
#   * data/thumbs/ and data/encoded-video/ — regenerable by Immich's own
#     jobs, per upstream's backup guidance. Excluding them saves real B2
#     storage. The trade-off is a slower recovery, since regenerating on
#     this box's Haswell CPU is not fast — accepted deliberately.
#   * pgdata/ — the live Postgres data directory. Upstream is explicit that
#     a file copy of it will not reliably restore; the dump in
#     data/backups/ is the supported path. Backing up both would be worse
#     than useless, because a torn datadir copy LOOKS like a valid backup.
#
# The repository password is NOT needed here: `kopia repository connect`
# persisted it to ~/.config/kopia/repository.config.kopia-password (0600),
# because this headless box has no keyring daemon for kopia to use.
set -eu

KOPIA="$HOME/.local/bin/kopia"
IMMICH_DATA="$HOME/immich/data"
LITELLM_DIR="$HOME/litellm"
LITELLM_DUMPS="$LITELLM_DIR/dumps"
LITELLM_KEEP=7
LOG="$HOME/kopia-immich/backup.log"
APPRISE_URL="https://apprise.mathewcsims.uk/notify/self-hosted"

mkdir -p "$(dirname "$LOG")"

log() {
    echo "[$(date -Is)] $1" >> "$LOG"
}

notify_failure() {
    # Best-effort, no retry — same curl-to-Apprise pattern as
    # pi-unattended-upgrades/notify-reboot-required.sh and
    # pi-fail2ban/notify-apprise.sh.
    curl -fsS --max-time 10 \
        --data-urlencode "title=⚠️ Immich backup FAILED on slartibartfast" \
        --data-urlencode "type=failure" \
        --data-urlencode "format=markdown" \
        --data-urlencode "body=$1" \
        "$APPRISE_URL" >/dev/null 2>&1 || true
}

log "=== starting Immich backup ==="

FAILED=""
for sub in library upload profile backups; do
    SRC="$IMMICH_DATA/$sub"
    if [ ! -d "$SRC" ]; then
        log "SKIP $sub — directory does not exist yet"
        continue
    fi
    # --log-level=error keeps the log readable; kopia still exits non-zero
    # and prints on real failures.
    if "$KOPIA" snapshot create "$SRC" --log-level=error >> "$LOG" 2>&1; then
        log "OK   $sub"
    else
        log "FAIL $sub"
        FAILED="$FAILED $sub"
    fi
done

# ── LiteLLM ──────────────────────────────────────────────────────────────
# Added 2026-08-04: until then LiteLLM had NO backup at all, on any host.
# Its Postgres holds the virtual API keys, per-key budgets and the whole
# spend history — losing it means re-issuing every key and losing all
# usage accounting.
#
# Dumped, not file-copied, for the same reason pgdata/ is skipped above and
# the same reason the Mac and Pi dump their databases before snapshotting:
# a file-level copy of a running Postgres datadir can capture torn pages
# and looks like a valid backup right up until you try to restore it.
# pg_dump runs INSIDE the container, so no credential ever reaches this
# host's command line — POSTGRES_USER/POSTGRES_DB come from the container's
# own environment.
#
# Not backed up, deliberately: litellm/pgdata (the live datadir — see
# above), litellm/ts-state (Tailscale node identity, root-owned; a lost
# node is re-authed in seconds), and compose.yaml/config.yaml/serve.json
# (versioned in this repo already, so a copy here would only ever go
# stale against it).
log "--- LiteLLM ---"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'litellm-db'; then
    mkdir -p "$LITELLM_DUMPS"
    _stamp=$(date +%Y%m%dT%H%M%S)
    _out="$LITELLM_DUMPS/litellm-$_stamp.sql.gz"
    if docker exec litellm-db sh -c 'exec pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' 2>>"$LOG" | gzip > "$_out"; then
        # A dump that "succeeded" but is a few bytes is a failed dump —
        # same guard as the Mac and Pi dump scripts.
        if [ "$(wc -c < "$_out")" -lt 500 ]; then
            rm -f "$_out"; log "FAIL litellm (dump suspiciously small)"; FAILED="$FAILED litellm-dump"
        else
            log "OK   litellm dump ($(du -h "$_out" | cut -f1))"
            # Bound local disk; Kopia keeps the real history.
            ls -t "$LITELLM_DUMPS"/litellm-*.sql.gz 2>/dev/null \
                | tail -n +$((LITELLM_KEEP + 1)) \
                | while read -r _old; do rm -f "$_old"; done
            if "$KOPIA" snapshot create "$LITELLM_DUMPS" --log-level=error >> "$LOG" 2>&1; then
                log "OK   litellm-dumps"
            else
                log "FAIL litellm-dumps"; FAILED="$FAILED litellm-dumps"
            fi
        fi
    else
        rm -f "$_out"; log "FAIL litellm (pg_dump)"; FAILED="$FAILED litellm-dump"
    fi
else
    log "SKIP litellm — litellm-db container is not running"
fi

if [ -n "$FAILED" ]; then
    log "=== FAILED for:$FAILED ==="
    notify_failure "Kopia snapshot failed for:$FAILED

Host: slartibartfast
Log: $LOG

Immich's photo library is the least replaceable data in the stack — worth
checking promptly rather than waiting for the next run."
    exit 1
fi

log "=== completed successfully ==="
