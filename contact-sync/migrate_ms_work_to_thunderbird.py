"""One-time migration (2026-07-25): re-link the 21 canonical contacts
currently holding a stale macOS Contacts.app ID under sources.ms_work to
their new Thunderbird UID, matched by exact name only.

Why this has to run once, standalone, before the new spoke can operate
normally: sync.py's generic new-contact logic matches providers to
canonical purely by (provider, provider_id) pairs stored in
canonical[*]["sources"]. Since the ID space is changing entirely (old
macOS ABPerson IDs -> new Thunderbird card UIDs), every one of the 21
existing work contacts would otherwise look brand new to sync.py on the
first run — and since ms_work contacts are specially auto-added as new
canonical entries (see sync.py's module docstring), that would create 21
duplicate canonical contacts instead of recognizing the 21 that already
exist. Re-pointing sources.ms_work at the new UID *before* the first
real sync run avoids that entirely.

Matching is exact-name-only (case/whitespace-normalized) — no fuzzy
matching, by explicit instruction: anything not an unambiguous exact
match gets left alone and reported, never guessed. Run with --apply to
actually write; without it, only prints/writes the report.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import thunderbird_client  # noqa: E402

DATA = os.path.expanduser("~/contact-sync")


def norm_name(s):
    return " ".join((s or "").split()).strip().lower()


# Confirmed by Mathew directly (2026-07-25) — same entities, reworded
# between the two systems, not exact name matches so the automatic
# matcher correctly declined to guess them. Keyed by canonical name.
MANUAL_OVERRIDES = {
    "RAL Site Security EMERGENCY": "15515765-2504-4977-8050-f573fd742010",  # "EMERGENCY RAL Security"
    "RAL Security Room": "35c18dd5-e140-41c7-bde4-acf94958d4db",  # "RAL Security Control Room"
    "Huw Palmer": "bfaacf62-a37b-41f3-a460-c412a792bce6",  # "Huw (David) Palmer"
    "HOW Control": "6d5eb785-c98c-454d-8f84-5e41afb295cc",  # "HOW Event Control"
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="write changes; default is dry-run")
    ap.add_argument("--canonical", default=os.path.join(DATA, "canonical.json"))
    ap.add_argument("--report", default=os.path.join(DATA, "migration-report.md"))
    args = ap.parse_args()

    canonical = json.load(open(args.canonical))
    tb_contacts = thunderbird_client.work_contacts()
    print(f"found {len(tb_contacts)} contacts in the work address book "
          f"({thunderbird_client.WORK_ADDRESS_BOOK_ID})")

    by_name = {}
    for c in tb_contacts:
        by_name.setdefault(norm_name(c["displayName"]), []).append(c)

    migrated, ambiguous, not_found = [], [], []
    for c in canonical:
        old_ids = c["sources"].get("ms_work", [])
        if not old_ids:
            continue
        if c["name"] in MANUAL_OVERRIDES:
            new_id = MANUAL_OVERRIDES[c["name"]]
            migrated.append((c["name"] + " (manual override)", old_ids[0], new_id))
            if args.apply:
                c["sources"]["ms_work"] = [new_id]
            continue
        candidates = by_name.get(norm_name(c["name"]), [])
        if len(candidates) == 1:
            new_id = candidates[0]["id"]
            migrated.append((c["name"], old_ids[0], new_id))
            if args.apply:
                c["sources"]["ms_work"] = [new_id]
        elif len(candidates) > 1:
            ambiguous.append((c["name"], old_ids[0], [x["id"] for x in candidates]))
        else:
            not_found.append((c["name"], old_ids[0]))

    lines = [f"# ms_work -> Thunderbird migration report ({'APPLIED' if args.apply else 'DRY RUN'})\n"]
    lines.append(f"**{len(migrated)} matched exactly and {'migrated' if args.apply else 'would be migrated'}:**")
    for name, old, new in migrated:
        lines.append(f"- {name}: `{old}` -> `{new}`")
    lines.append(f"\n**{len(ambiguous)} ambiguous (multiple exact name matches — needs manual review):**")
    for name, old, news in ambiguous:
        lines.append(f"- {name}: `{old}` -> one of {news} — pick manually, not auto-applied")
    lines.append(f"\n**{len(not_found)} no match found in Thunderbird's work address book "
                 f"(name may have changed, or the person left — needs manual review):**")
    for name, old in not_found:
        lines.append(f"- {name}: `{old}` — left un-migrated, will keep failing to sync until resolved")

    report = "\n".join(lines)
    with open(args.report, "w") as f:
        f.write(report)
    print(report)

    if args.apply:
        with open(args.canonical, "w") as f:
            json.dump(canonical, f, indent=1)
        print(f"\ncanonical.json updated. Full report: {args.report}")
    else:
        print(f"\nDRY RUN — nothing written. Re-run with --apply to commit. Report: {args.report}")


if __name__ == "__main__":
    main()
