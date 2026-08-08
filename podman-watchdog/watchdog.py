"""Podman-on-Mac dead-man's-switch — added 2026-07-26 after the machine's
virtio block-device worker thread wedged (heavy sustained container disk
I/O — see SETUP.md's Podman Watchdog section for the diagnosis) and every
container silently became unreachable via `podman ps` for ~2 days before
being noticed. That failure mode is exactly why this pings OUT rather
than being polled: Uptime Kuma's other ~24 monitors reach apps over the
network, but the failure here was the Mac's own local Podman socket
hanging — nothing external could have told the difference between "app
down" and "Podman itself wedged" without this.

Run every 2 minutes via launchd (uk.mathewcsims.podman-watchdog). Each
run does ONE bounded-timeout `podman ps` — if it answers in time, pings
Uptime Kuma's push monitor with status=up; if it times out or errors,
pings status=down with the reason. A hard subprocess timeout is
essential: this script exists because `podman ps` can itself hang
indefinitely when the VM is wedged, so it must never block longer than
the interval it's scheduled at.

Secrets: KUMA_PUSH_TOKEN from the "Uptime Kuma" Pass item, sourced by
run-watchdog.sh — never argv, never a file.
"""

import errno
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request

PODMAN_TIMEOUT = 15
PUSH_TIMEOUT = 10
PUSH_BASE = "https://status.mathewcsims.uk/api/push/"

# ── Remediation (added 2026-08-08) ────────────────────────────────────────
#
# Until now this only REPORTED. On 2026-08-08 the VM died ~90 seconds after a
# clean post-reboot start; this script correctly detected it 43 seconds in and
# correctly pinged Kuma down — and then the stack stayed down until a human
# happened to look. That is the whole gap: detection was never the problem,
# and a dead-man's-switch that can only report turns every VM death into an
# outage lasting until someone notices. At 3am that is hours.
#
# So it now tries to restart the machine, with three guards against a
# watchdog that makes things worse:
#
#   * FAILURES_BEFORE_RESTART — never act on a single failure. At a 120s
#     interval this means ~2-4 minutes of confirmed-dead before intervening,
#     which is deliberately longer than a normal `podman machine start` takes.
#     Without it, the watchdog would fight podman-autostart.sh during every
#     boot: it saw exactly such a transient failure 43s into the last one,
#     while autostart was still mid-start.
#   * RESTART_COOLDOWN — a machine that dies immediately after starting must
#     not become a restart loop hammering the host.
#   * MAX_RESTART_ATTEMPTS — if three attempts have not fixed it, the fault
#     is not one a restart fixes. Stop, say so loudly, leave it for a human.
#     The cap is per-outage, reset on the first success.
#
# A lock file makes the restart itself mutually exclusive, because
# `podman machine start` takes longer than the scheduling interval and two
# overlapping starts is its own failure mode.
FAILURES_BEFORE_RESTART = 2
MAX_RESTART_ATTEMPTS = 3
RESTART_COOLDOWN = 600
MACHINE_START_TIMEOUT = 240
MACHINE = "podman-machine-default"

STATE_DIR = os.path.expanduser("~/podman-watchdog")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
LOCK_FILE = os.path.join(STATE_DIR, "restart.lock")

# Real notifications go to Apprise, not Kuma. A Kuma push can only move a
# monitor between up and down — it has no way to say "I restarted your VM",
# which is exactly the thing worth telling someone about.
APPRISE_URL = "https://apprise.mathewcsims.uk/notify/self-hosted"


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"consecutive_failures": 0, "restart_attempts": 0, "last_restart": 0}


def save_state(state):
    try:
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f)
        os.replace(tmp, STATE_FILE)
    except OSError as e:
        print(f"state write failed: {e}", file=sys.stderr)


def alert(title, body, kind="warning"):
    data = urllib.parse.urlencode({
        "title": title,
        "type": kind,
        "format": "markdown",
        "body": body + "\n\nHost: mathews-mac",
    }).encode()
    try:
        urllib.request.urlopen(APPRISE_URL, data=data, timeout=PUSH_TIMEOUT)
    except OSError as e:
        # Same tradeoff as push(): never fatal. The Kuma monitor is the
        # backstop — it is already down by the time we get here.
        print(f"alert failed: {e}", file=sys.stderr)


def try_restart(state, reason):
    """Attempt one `podman machine start`, honouring cap, cooldown and lock."""
    now = time.time()

    if state["restart_attempts"] >= MAX_RESTART_ATTEMPTS:
        print(f"restart cap reached ({MAX_RESTART_ATTEMPTS}) — not retrying", file=sys.stderr)
        return

    since = now - state["last_restart"]
    if state["last_restart"] and since < RESTART_COOLDOWN:
        print(f"in cooldown ({int(RESTART_COOLDOWN - since)}s left) — not retrying", file=sys.stderr)
        return

    # Mutual exclusion: O_EXCL create, so a start already running (from a
    # previous run of this script, or podman-autostart.sh) wins and we skip.
    try:
        fd = os.open(LOCK_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except OSError as e:
        if e.errno == errno.EEXIST:
            # Stale lock from a killed run would block every future restart,
            # which is the same outage in a different costume — time it out.
            try:
                if now - os.path.getmtime(LOCK_FILE) > MACHINE_START_TIMEOUT * 2:
                    os.unlink(LOCK_FILE)
                    print("removed stale restart lock", file=sys.stderr)
            except OSError:
                pass
            print("a machine start is already in progress — skipping", file=sys.stderr)
            return
        raise
    os.close(fd)

    state["restart_attempts"] += 1
    state["last_restart"] = now
    attempt = state["restart_attempts"]
    save_state(state)

    try:
        r = subprocess.run(["podman", "machine", "start", MACHINE],
                           capture_output=True, text=True, timeout=MACHINE_START_TIMEOUT)
        ok = r.returncode == 0
        detail = (r.stderr or r.stdout or "").strip()[-300:]
    except subprocess.TimeoutExpired:
        ok = False
        detail = f"`podman machine start` did not return within {MACHINE_START_TIMEOUT}s"
    except Exception as e:  # noqa: BLE001 — must never take the watchdog down
        ok = False
        detail = f"{e}"
    finally:
        try:
            os.unlink(LOCK_FILE)
        except OSError:
            pass

    if ok:
        alert(
            "⚠️ Podman VM was down — restarted automatically",
            f"The Podman machine stopped responding (`{reason}`) and was restarted "
            f"automatically on attempt {attempt} of {MAX_RESTART_ATTEMPTS}.\n\n"
            "Every Mac-hosted app was down until this ran. Worth checking "
            "`podman-watchdog/launchd.log` and `autostart/autostart.log` for why "
            "the VM stopped — the restart treats the symptom, not the cause.",
            "warning",
        )
    else:
        alert(
            "🔴 Podman VM is down and the restart FAILED",
            f"The Podman machine stopped responding (`{reason}`), and attempt "
            f"{attempt} of {MAX_RESTART_ATTEMPTS} to restart it failed:\n\n"
            f"    {detail}\n\n"
            "**Every Mac-hosted app is down.** This needs a human:\n\n"
            "    podman machine start\n"
            "    sh ~/self-hosted/autostart/podman-autostart.sh",
            "failure",
        )


def push(token, status, msg):
    url = PUSH_BASE + token + "?" + urllib.parse.urlencode({"status": status, "msg": msg, "ping": ""})
    try:
        urllib.request.urlopen(url, timeout=PUSH_TIMEOUT)
    except OSError as e:
        # Network to the Pi is down, or Kuma itself is down — nothing more
        # to do; Kuma's own missed-heartbeat detection is the fallback for
        # this specific case (it will flag the monitor as down on its own
        # once enough pings are missed).
        print(f"push failed: {e}", file=sys.stderr)


def probe():
    """One bounded `podman ps`. Returns (ok, kuma_message)."""
    try:
        r = subprocess.run(["podman", "ps", "--format", "{{.Names}}"],
                           capture_output=True, text=True, timeout=PODMAN_TIMEOUT)
        if r.returncode == 0:
            n = len(r.stdout.strip().splitlines())
            return True, f"{n} containers responding"
        return False, f"podman ps exited {r.returncode}: {r.stderr[-200:]}"
    except subprocess.TimeoutExpired:
        return False, f"podman ps did not respond within {PODMAN_TIMEOUT}s — VM likely wedged"
    except Exception as e:  # noqa: BLE001 — a watchdog must not die on surprises
        return False, f"watchdog error: {e}"


def main():
    token = os.environ["KUMA_PUSH_TOKEN"]
    state = load_state()

    ok, msg = probe()
    push(token, "up" if ok else "down", msg)

    if ok:
        # First success ends the outage: clear the failure run AND the
        # per-outage restart cap, so a later, unrelated failure gets its own
        # three attempts rather than inheriting an exhausted budget.
        if state["consecutive_failures"] or state["restart_attempts"]:
            state.update(consecutive_failures=0, restart_attempts=0)
            save_state(state)
        return

    state["consecutive_failures"] += 1
    save_state(state)

    if state["consecutive_failures"] >= FAILURES_BEFORE_RESTART:
        try_restart(state, msg)
        save_state(state)


if __name__ == "__main__":
    main()
