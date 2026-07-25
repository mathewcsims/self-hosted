"""MS work spoke — Thunderbird MCP extension's local HTTP API, ASYMMETRIC
by design (unchanged from the original macOS Contacts.app version this
replaces 2026-07-25). Same agreed scope: the work account's own ~21
contacts sync outward to every personal provider, and canonical updates
to THOSE contacts sync back in — but personal contacts are never pushed
into the work address book. So, like before: plan/apply produce updates
ONLY for contacts that already exist there. No creates, no deletes.

Requires a completed one-time run of migrate_ms_work_to_thunderbird.py
first — this spoke assumes sources["ms_work"] already holds a real
Thunderbird contact UID, not the old macOS Contacts.app ID.

Requires Thunderbird to be running with the MCP extension loaded (see
thunderbird_client.py) — if it's not, pull() raises
ThunderbirdUnavailable, which sync.py's generic per-provider try/except
already handles the same way an offline proton-cli or a network failure
would (that spoke skipped, everything else proceeds).
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import normalize  # noqa: E402
import thunderbird_client  # noqa: E402


def pull(tmp_path=None):
    """tmp_path accepted for interface parity with the other spokes
    (sync.py's pull_provider always passes one) but unused — there's no
    intermediate file, the extension's API is called directly."""
    raw = thunderbird_client.work_contacts()
    return normalize.from_thunderbird(raw)


def differs(canon, work):
    return (
        sorted(canon["emails"]) != sorted(work["emails"])
        or sorted(canon["phones"]) != sorted(work["phones"])
        or (canon["org"] or "") != (work["org"] or "")
        or (canon["title"] or "") != (work["title"] or "")
        or (canon["notes"] or "") != (work["notes"] or "")
    )


def make_plan(canonical_path, out_path):
    current = {c["source_id"]: c for c in pull()}
    canonical = json.load(open(canonical_path))
    plan = {"update": [], "unchanged": 0, "missing": [],
           "note": "asymmetric spoke: updates only, no creates/deletes"}
    for c in canonical:
        ids = c["sources"].get("ms_work", [])
        if not ids:
            continue  # personal-only contact: never pushed into work
        wid = ids[0]
        if wid not in current:
            # Genuinely worth surfacing, not silently skipping: means the
            # contact vanished from Thunderbird's work address book since
            # the last migration/sync (renamed again, or left).
            plan["missing"].append({"uid": c["uid"], "work_id": wid, "name": c["name"]})
            continue
        if differs(c, current[wid]):
            plan["update"].append({"uid": c["uid"], "work_id": wid, "name": c["name"]})
        else:
            plan["unchanged"] += 1
    with open(out_path, "w") as f:
        json.dump(plan, f, indent=1)
    os.chmod(out_path, 0o600)
    print(f"plan: update {len(plan['update'])}, unchanged {plan['unchanged']}, "
          f"missing {len(plan['missing'])} (no creates/deletes by design)")
    if plan["missing"]:
        print("  MISSING from Thunderbird's work address book (was linked before, isn't now):",
              file=sys.stderr)
        for m in plan["missing"]:
            print(f"    {m['name']} (was {m['work_id']})", file=sys.stderr)


def apply_plan(plan_path, canonical_path):
    # Note: one write was observed to silently no-op once during testing
    # (updateContact returned success but getContact still showed the old
    # value moments later, with no retry needed — it worked on the very
    # next identical call). Cause unconfirmed (possibly a momentary
    # extension/Thunderbird hiccup). Not retried here: this runs daily via
    # launchd and make_plan() is idempotent, so a missed write just shows
    # up again in tomorrow's plan.
    plan = json.load(open(plan_path))
    canonical = {c["uid"]: c for c in json.load(open(canonical_path))}
    updated = failed = 0
    for item in plan["update"]:
        c = canonical[item["uid"]]
        # phones need {type, number} per the extension's own schema, not
        # bare strings — "work" as a reasonable default type, matching
        # how the old macOS spoke labeled pushed numbers "work" too.
        phones = [{"type": "work", "number": p} for p in c["phones"]]
        # Omit fields entirely rather than pass None — the extension's
        # updateContact rejects an explicit null for a string-typed field
        # (whole call fails), it does not treat null as "leave unchanged"
        # the way omission does. Confirmed live: sending organization=None
        # alongside a real email/phones silently dropped the entire
        # update (call_tool didn't surface the tool-level error either,
        # separately fixed in thunderbird_client.py).
        fields = {}
        if c["emails"]:
            fields["email"] = c["emails"][0]
        if c["org"]:
            fields["organization"] = c["org"]
        if c["title"]:
            fields["title"] = c["title"]
        if c["notes"]:
            fields["note"] = c["notes"]
        if phones:
            fields["phones"] = phones
        try:
            thunderbird_client.update_contact(item["work_id"], **fields)
            updated += 1
        except Exception as e:
            print(f"UPDATE FAILED {item['name']!r}: {e}", file=sys.stderr)
            failed += 1
    print(f"applied: updated {updated}, failed {failed} (asymmetric — nothing created/deleted)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["plan", "apply"])
    ap.add_argument("--canonical", required=True)
    ap.add_argument("--out")
    ap.add_argument("--plan")
    args = ap.parse_args()
    if args.mode == "plan":
        make_plan(args.canonical, args.out or "ms-work-plan.json")
    else:
        apply_plan(args.plan, args.canonical)


if __name__ == "__main__":
    main()
