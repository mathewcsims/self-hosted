"""Proton spoke — plan (dry-run) and apply via the audited proton-cli
build (~/bin/proton-cli, pinned commit + the one-line list patch in
patches/).

Auth: PROTON_USER / PROTON_PASSWORD in the environment for the first
login only; routine runs reuse the CLI's own session file (encrypted key
blob, see the Phase 0 audit notes in SETUP.md). No TOTP needed after the
first login.

Each mutation is one CLI invocation (~3s: session load + key unlock per
process) — fine for the convergence batch and for the small deltas of
routine syncs. Contact field values pass via argv, accepted deliberately:
they're personal data on Mathew's own single-user Mac, not credentials —
the never-in-argv rule protects secrets, and none of these are.
"""

import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import normalize  # noqa: E402

CLI = os.path.expanduser("~/bin/proton-cli")


def run_cli(args):
    # Flags must precede any "--" separator (everything after it is
    # positional) — splice --output json in before it.
    if "--" in args:
        i = args.index("--")
        full = args[:i] + ["--output", "json"] + args[i:]
    else:
        full = args + ["--output", "json"]
    return subprocess.run([CLI] + full, capture_output=True, text=True, timeout=120)


def pull_all(tmp_path):
    r = run_cli(["contacts", "list"])
    if r.returncode != 0:
        raise RuntimeError(f"proton-cli list failed: {r.stderr[-300:]}")
    with open(tmp_path, "w") as f:
        f.write(r.stdout)
    os.chmod(tmp_path, 0o600)
    return normalize.from_proton(tmp_path)


def differs(canon, prot):
    # Notes compared only when canonical HAS one: proton-cli update cannot
    # clear a note (an empty --note is ignored, confirmed live), so a
    # canonical-empty vs provider-stale-note mismatch would flag an update
    # that can never converge. Stale leftover notes in Proton are accepted
    # as cosmetic; every other provider's API can clear notes properly.
    notes_differ = bool(canon["notes"]) and canon["notes"] != (prot["notes"] or "")
    return (
        sorted(canon["emails"]) != sorted(prot["emails"])
        or sorted(canon["phones"]) != sorted(prot["phones"])
        or (canon["name"] or "") != (prot["name"] or "")
        or (canon["org"] or "") != (prot["org"] or "")
        or (canon["title"] or "") != (prot["title"] or "")
        or notes_differ
    )


def field_args(c):
    args = []
    name = c["name"]
    if not name and not c["emails"] and c["phones"]:
        # proton-cli requires a name or an email; phone-only contacts
        # use their number as the display name (matching provider UIs).
        name = c["phones"][0]
    if name:
        args += ["--name", name]
    for e in c["emails"]:
        args += ["--email", e]
    for p in c["phones"]:
        args += ["--phone", p]
    if c["org"]:
        args += ["--org", c["org"]]
    if c["title"]:
        args += ["--title", c["title"]]
    if c["notes"]:
        args += ["--note", c["notes"]]
    if c["birthday"] and not c["birthday"].startswith("--"):
        args += ["--birthday", c["birthday"]]
    if c["urls"]:
        args += ["--url", c["urls"][0]]
    return args


def make_plan(canonical_path, out_path, current_dump):
    current = {c["source_id"]: c for c in pull_all(current_dump)}
    canonical = json.load(open(canonical_path))
    plan = {"create": [], "update": [], "delete": [], "unchanged": 0}
    for c in canonical:
        if c.get("excluded"):
            continue  # import-artifact husks etc. — never synced anywhere
        ids = c["sources"].get("proton", [])
        if not ids:
            plan["create"].append({"uid": c["uid"], "name": c["name"]})
            continue
        survivor = ids[0]
        for dup in ids[1:]:
            plan["delete"].append({"uid": c["uid"], "proton_id": dup,
                                   "name": c["name"],
                                   "reason": "intra-proton duplicate merged"})
        if survivor in current and differs(c, current[survivor]):
            plan["update"].append({"uid": c["uid"], "proton_id": survivor,
                                   "name": c["name"]})
        else:
            plan["unchanged"] += 1
    with open(out_path, "w") as f:
        json.dump(plan, f, indent=1)
    os.chmod(out_path, 0o600)
    print(f"plan: create {len(plan['create'])}, update {len(plan['update'])}, "
          f"delete {len(plan['delete'])} (intra-proton dups), unchanged {plan['unchanged']}")


def apply_plan(plan_path, canonical_path, state_path):
    plan = json.load(open(plan_path))
    canonical = {c["uid"]: c for c in json.load(open(canonical_path))}
    state = json.load(open(state_path))

    created = updated = deleted = failed = 0
    for item in plan["create"]:
        c = canonical[item["uid"]]
        r = run_cli(["contacts", "create"] + field_args(c))
        if r.returncode == 0:
            # create prints the bare contact ID as plain text (even with
            # --output json) — found live when 316 create IDs went
            # unrecorded and got duplicated on the retry run.
            new_id = r.stdout.strip().split("\n")[-1].strip()
            if new_id:
                c["sources"]["proton"] = [new_id]
                state["contacts"][c["uid"]]["providers"]["proton"] = [new_id]
            created += 1
        else:
            print(f"CREATE FAILED {item['name']!r}: {r.stderr[-200:]}", file=sys.stderr)
            failed += 1
    for item in plan["update"]:
        c = canonical[item["uid"]]
        r = run_cli(["contacts", "update"] + field_args(c) + ["--", item["proton_id"]])
        if r.returncode == 0:
            updated += 1
        else:
            print(f"UPDATE FAILED {item['name']!r}: {r.stderr[-200:]}", file=sys.stderr)
            failed += 1
    dup_ids = [item["proton_id"] for item in plan["delete"]]
    if dup_ids:
        r = run_cli(["contacts", "delete", "--"] + dup_ids)
        if r.returncode == 0:
            deleted = len(dup_ids)
            # prune deleted IDs so future plans never retry them
            for item in plan["delete"]:
                c = canonical[item["uid"]]
                c["sources"]["proton"] = [i for i in c["sources"].get("proton", [])
                                          if i != item["proton_id"]]
                state["contacts"][item["uid"]]["providers"]["proton"] = c["sources"]["proton"]
        else:
            print(f"DELETE FAILED: {r.stderr[-200:]}", file=sys.stderr)
            failed += len(dup_ids)

    with open(canonical_path, "w") as f:
        json.dump(list(canonical.values()), f, indent=1)
    with open(state_path, "w") as f:
        json.dump(state, f, indent=1)
    print(f"applied: created {created}, updated {updated}, deleted {deleted}, failed {failed}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["plan", "apply"])
    ap.add_argument("--canonical", required=True)
    ap.add_argument("--out")
    ap.add_argument("--plan")
    ap.add_argument("--state")
    ap.add_argument("--current-dump", default="/tmp/proton-current.json")
    args = ap.parse_args()
    if args.mode == "plan":
        make_plan(args.canonical, args.out or "proton-plan.json", args.current_dump)
    else:
        apply_plan(args.plan, args.canonical, args.state)


if __name__ == "__main__":
    main()
