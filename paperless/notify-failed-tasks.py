#!/usr/bin/env python3
"""Alert via Apprise when a Paperless background task fails.

Run hourly by uk.mathewcsims.paperless-task-alert (LaunchAgent) — see
paperless/uk.mathewcsims.paperless-task-alert.plist.

── WHY THIS EXISTS ───────────────────────────────────────────────────────
Paperless task failures are silent in the worst way. The app stays up and
keeps serving; only the Celery task dies. On 2026-08-05 every hourly
`train_classifier` task had been OOM-killed for nine hours straight, and the
only symptom was tag suggestions quietly going stale — noticed by chance
from a badge in the web UI. Nothing alerted.

The same applies to `consume_file`: a failed one means a document was
dropped in the consume folder and never became a document, which looks
identical to "not scanned yet" until you go looking.

Paperless has no native hook for this. Its workflow system has a Webhook
ACTION, but the only triggers are Consumption Started / Document Added /
Document Updated / Scheduled — none fire on task failure. So this polls.

── WHY IT READS SQLITE DIRECTLY ─────────────────────────────────────────
Rather than `podman exec paperless python3 manage.py ...`:

  * It works when the container is unhealthy or stopped — which is exactly
    when failures matter most. An alerting path that depends on the thing
    it monitors is not much of an alerting path.
  * It is far quicker than spinning up a Django shell every hour.
  * There is precedent: scripts/dump-databases.sh already opens these same
    databases read-only from the host.

Opened with mode=ro. Paperless runs SQLite in WAL mode, which permits
concurrent readers, so this cannot block or corrupt anything.

── WHY A STATE FILE RATHER THAN THE `acknowledged` COLUMN ───────────────
PaperlessTask has an `acknowledged` flag — the UI's "Dismiss" button. It is
deliberately NOT used to track what has been alerted on:

  * Reading it would mean staying silent about any failure that had not
    been dismissed, which is backwards.
  * Setting it would dismiss tasks in the web UI on the user's behalf,
    destroying the exact signal that surfaced the OOM problem in the first
    place.

So a high-water-mark file records the highest task id alerted on. The two
mechanisms stay independent: dismissing in the UI does not suppress alerts,
and alerting does not clear the UI.
"""

# Runs under macOS's /usr/bin/python3 (same as trivy-scan's LaunchAgent), which
# is older than the Homebrew one and evaluates annotations eagerly — so
# `int | None` in a signature raises TypeError at import despite compiling
# fine. This makes annotations lazy strings and keeps the file working on
# both. Caught by running it, not by py_compile, which never evaluates them.
from __future__ import annotations

import json
import sqlite3
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DB = REPO_ROOT / "paperless" / "data" / "db.sqlite3"
STATE = REPO_ROOT / "paperless" / ".notify-state"
APPRISE_URL = "https://apprise.mathewcsims.uk/notify/self-hosted"

# Same ceiling and reasoning as trivy-scan/scan.py: Discord embed
# descriptions cap at 4096 characters, and blowing through it 400s the whole
# Apprise fan-out — taking the ntfy copy down with it, not just the Discord
# one. A burst of failures must therefore summarise rather than enumerate.
MAX_NOTIFY_CHARS = 3500
MAX_LISTED = 8


def notify(title: str, body: str, ntype: str = "failure") -> None:
    data = urllib.parse.urlencode(
        {"title": title, "body": body[:MAX_NOTIFY_CHARS],
         "type": ntype, "format": "markdown"},
    ).encode()
    try:
        req = urllib.request.Request(APPRISE_URL, data=data, method="POST")
        urllib.request.urlopen(req, timeout=15)
    except OSError as e:
        print(f"notify failed: {e}", file=sys.stderr)
        sys.exit(1)


def read_state() -> int | None:
    try:
        return int(STATE.read_text().strip())
    except (OSError, ValueError):
        return None


def main() -> int:
    if not DB.exists():
        # Not an error worth alerting on — the app may simply not be
        # deployed on this machine. Say so and exit clean.
        print(f"no database at {DB}, nothing to check")
        return 0

    con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=10)
    try:
        rows = con.execute(
            "SELECT id, task_type, date_done, result_data "
            "FROM documents_paperlesstask WHERE status = 'failure' "
            "ORDER BY id",
        ).fetchall()
        max_id = con.execute(
            "SELECT COALESCE(MAX(id), 0) FROM documents_paperlesstask",
        ).fetchone()[0]
    finally:
        con.close()

    last = read_state()

    # FIRST RUN: record where we are and stay quiet. Alerting immediately
    # would fire about historical failures that have already been seen and
    # dealt with — the eight OOM kills from 2026-08-05 being exactly that.
    # An alerting system whose first act is a false alarm gets ignored.
    if last is None:
        STATE.write_text(str(max_id))
        print(f"first run — high-water mark set to {max_id}, no alert sent")
        return 0

    new = [r for r in rows if r[0] > last]
    if not new:
        print(f"no new failures (high-water mark {last}, latest task {max_id})")
        STATE.write_text(str(max_id))
        return 0

    # Group by type: nine identical OOM kills should read as one problem,
    # not nine. The per-type example carries the actual error text, which is
    # what tells you whether it is memory, a parser, or the NAS being away.
    by_type: dict[str, list] = {}
    for task_id, task_type, date_done, result_data in new:
        by_type.setdefault(task_type or "unknown", []).append(
            (task_id, date_done, result_data),
        )

    lines = []
    for task_type, items in sorted(by_type.items(), key=lambda kv: -len(kv[1])):
        lines.append(f"**{task_type}** — {len(items)} failure(s)")
        _, when, raw = items[-1]
        try:
            parsed = json.loads(raw) if raw else {}
            err = parsed.get("error_message") or parsed.get("error_type") or ""
        except (ValueError, TypeError):
            err = str(raw or "")[:120]
        lines.append(f"  latest {when}: `{err[:160]}`")

    total = len(new)
    body = "\n".join(lines[: MAX_LISTED * 2])
    if len(by_type) > MAX_LISTED:
        body += f"\n\n…and {len(by_type) - MAX_LISTED} more task type(s)."
    body += (
        f"\n\nSeen in Paperless at https://paperless.mathewcsims.uk/tasks "
        f"(Needs attention).\n\n"
        f"If these are `train_classifier` with signal 9 (SIGKILL), check the "
        f"corpus for oversized documents BEFORE raising mem_limit — see "
        f"SETUP.md's Paperless section.\n\nHost: mathews-mac"
    )

    notify(f"🚨 Paperless: {total} task failure(s)", body)
    STATE.write_text(str(max_id))
    print(f"alerted on {total} failure(s); high-water mark now {max_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
