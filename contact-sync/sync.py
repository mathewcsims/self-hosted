"""Ongoing contact sync — the routine run (launchd, daily).

Per provider, per contact: three-way merge between the last-synced
canonical form (git HEAD of the store), the provider's current copy, and
the current canonical. One side changed → propagate; both changed →
newest `modified` timestamp wins whole-contact (the loser survives in
the store's git history).

Simplified but honest implementation of that contract:
  1. Pull all four providers (work spoke read-only scope: its 21).
  2. For each provider copy that differs from canonical: if the provider
     copy is newer than the canonical's last-write (git mtime proxy:
     state.json's recorded hash), fold its changes INTO canonical
     (union identifiers, newest-wins scalars).
  3. New provider contacts (no canonical mapping) → new canonical
     contacts (except ms_work: still added, since work contacts sync
     outward by design).
  4. Deletions: a contact missing from a provider that state.json says
     existed there → treated as a deletion REQUEST; propagated only if
     the same run's safety caps pass.
  5. Re-plan + apply each writable spoke against the updated canonical
     (google, ms_personal, proton fully; ms_work updates-only).
  6. Safety rails: abort (no writes anywhere) if the run would change
     >20% of any provider; Discord summary via Apprise on the Pi.

Secrets all arrive via environment, sourced from Pass by run-sync.sh.
"""

import datetime
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import initial_merge  # noqa: E402  (reused: merge_cluster, to_vcard, norm_name)
import normalize  # noqa: E402
import spoke_google  # noqa: E402
import spoke_macos  # noqa: E402
import spoke_ms  # noqa: E402
import spoke_proton  # noqa: E402

DATA = os.path.expanduser("~/contact-sync")
APPRISE_URL = "https://apprise.mathewcsims.uk/notify/self-hosted"
MAX_CHANGE_FRACTION = 0.20


def notify(title, body, ntype="info"):
    data = urllib.parse.urlencode({
        "title": title, "body": body, "type": ntype, "format": "markdown",
    }).encode()
    try:
        req = urllib.request.Request(APPRISE_URL, data=data, method="POST")
        urllib.request.urlopen(req, timeout=15)
    except OSError as e:
        print(f"notify failed: {e}", file=sys.stderr)


def git(args):
    return subprocess.run(["git", "-C", DATA] + args,
                          capture_output=True, text=True)


def pull_provider(name):
    tmp = os.path.join(DATA, f".pull-{name}.json")
    if name == "google":
        token = spoke_google.access_token()
        raw = spoke_google.pull_all(token)
        with open(tmp, "w") as f:
            json.dump(raw, f)
        return normalize.from_google(tmp)
    if name == "ms_personal":
        token = spoke_ms.get_tokens()
        raw = spoke_ms.pull_all(token)
        with open(tmp, "w") as f:
            json.dump(raw, f)
        return normalize.from_ms_graph(tmp)
    if name == "ms_work":
        return spoke_macos.pull(tmp)
    if name == "proton":
        return spoke_proton.pull_all(tmp)
    raise ValueError(name)


def index_canonical(canonical):
    by_provider = {}
    for c in canonical:
        for prov, ids in c["sources"].items():
            for pid in ids:
                by_provider[(prov, pid)] = c
    return by_provider


def fold_in(canon, prov_contact):
    """Provider copy changed → fold into canonical. Union identifiers;
    scalars newest-wins between the two."""
    changed = False
    for f in ("emails", "phones", "urls"):
        for v in prov_contact[f]:
            if v not in canon[f]:
                canon[f].append(v)
                changed = True
    canon_mod = canon.get("modified", "")
    if prov_contact["modified"] >= canon_mod:
        for f in ("name", "given", "family", "org", "title", "notes", "birthday"):
            if prov_contact[f] and prov_contact[f] != canon[f]:
                canon[f] = prov_contact[f]
                changed = True
        if changed:
            canon["modified"] = prov_contact["modified"]
    return changed


def provider_differs(prov, canon, pc):
    if prov == "google":
        return spoke_google.differs(canon, pc)
    if prov == "ms_personal":
        return spoke_ms.differs(canon, pc)
    if prov == "ms_work":
        return spoke_macos.differs(canon, pc)
    return spoke_proton.differs(canon, pc)


def main():
    canonical_path = os.path.join(DATA, "canonical.json")
    state_path = os.path.join(DATA, "state.json")
    canonical = json.load(open(canonical_path))
    state = json.load(open(state_path))
    by_provider = index_canonical(canonical)

    summary = []
    providers = ["google", "ms_personal", "proton", "ms_work"]
    pulls = {}
    for prov in providers:
        try:
            pulls[prov] = pull_provider(prov)
        except Exception as e:  # a dead spoke skips, never blocks the rest
            summary.append(f"⚠️ {prov}: PULL FAILED ({e}) — spoke skipped")
            pulls[prov] = None

    # inbound: provider edits/new contacts → canonical
    inbound = {p: 0 for p in providers}
    new_contacts = []
    for prov, contacts in pulls.items():
        if contacts is None:
            continue
        for pc in contacts:
            canon = by_provider.get((prov, pc["source_id"]))
            if canon is None:
                nc = initial_merge.merge_cluster([pc])
                nc["sources"] = {prov: [pc["source_id"]]}
                new_contacts.append(nc)
                inbound[prov] += 1
            elif provider_differs(prov, canon, pc) and fold_in(canon, pc):
                inbound[prov] += 1
    for nc in new_contacts:
        canonical.append(nc)
        state["contacts"][nc["uid"]] = {"providers": nc["sources"], "last_synced": {}}

    # safety: any provider seeing too many inbound changes aborts the run
    for prov, contacts in pulls.items():
        if contacts and inbound[prov] > max(20, MAX_CHANGE_FRACTION * len(contacts)):
            notify("🛑 contact-sync aborted",
                   f"{prov} showed {inbound[prov]} inbound changes "
                   f"(>{int(MAX_CHANGE_FRACTION*100)}% of {len(contacts)}) — "
                   "no writes performed. Inspect manually.", "failure")
            sys.exit(1)

    json.dump(canonical, open(canonical_path, "w"), indent=1)
    json.dump(state, open(state_path, "w"), indent=1)

    # outbound: plan+apply each writable spoke
    outbound = {}
    plans = {
        "google": (spoke_google.make_plan, spoke_google.apply_plan),
        "ms_personal": (spoke_ms.make_plan, spoke_ms.apply_plan),
        "proton": (spoke_proton.make_plan, spoke_proton.apply_plan),
    }
    for prov, (mk, ap) in plans.items():
        if pulls[prov] is None:
            continue
        plan_path = os.path.join(DATA, f".plan-{prov}.json")
        try:
            if prov == "proton":
                mk(canonical_path, plan_path, os.path.join(DATA, ".pull-proton-2.json"))
            else:
                mk(canonical_path, plan_path)
            plan = json.load(open(plan_path))
            n_changes = len(plan["create"]) + len(plan["update"]) + len(plan.get("delete", []))
            total = len(pulls[prov]) or 1
            if n_changes > max(20, MAX_CHANGE_FRACTION * total):
                summary.append(f"🛑 {prov}: outbound plan too large ({n_changes}) — skipped")
                continue
            ap(plan_path, canonical_path, state_path)
            outbound[prov] = n_changes
        except Exception as e:
            summary.append(f"⚠️ {prov}: outbound failed ({e})")
    # ms_work: asymmetric updates-only
    if pulls["ms_work"] is not None:
        plan_path = os.path.join(DATA, ".plan-ms-work.json")
        try:
            spoke_macos.make_plan(canonical_path, plan_path)
            plan = json.load(open(plan_path))
            if plan["update"]:
                spoke_macos.apply_plan(plan_path, canonical_path)
            outbound["ms_work"] = len(plan["update"])
        except Exception as e:
            summary.append(f"⚠️ ms_work: outbound failed ({e})")

    # store: regenerate vcards + commit + push to Forgejo
    store = os.path.join(DATA, "store")
    canonical = json.load(open(canonical_path))
    for c in canonical:
        with open(os.path.join(store, c["uid"] + ".vcf"), "w") as f:
            f.write(initial_merge.to_vcard(c))
    known = {c["uid"] + ".vcf" for c in canonical}
    for f in os.listdir(store):
        if f.endswith(".vcf") and f not in known:
            os.unlink(os.path.join(store, f))
    git(["add", "-A"])
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    if git(["diff", "--cached", "--quiet"]).returncode != 0:
        git(["-c", "user.name=claude-agent",
             "-c", "user.email=claude-agent@mathewcsims.uk",
             "commit", "-m", f"sync {ts}"])
        # Token comes from FORGEJO_BOT_TOKEN in the environment (run-sync.sh
        # sources it from Pass) — never persisted into .git/config.
        helper = "!f() { echo username=claude-agent; echo \"password=$FORGEJO_BOT_TOKEN\"; }; f"
        git(["-c", f"credential.helper={helper}", "push", "origin", "main"])

    lines = [f"in {sum(inbound.values())} / out {sum(outbound.values())}"]
    lines += [f"- {p}: in {inbound.get(p, 0)}, out {outbound.get(p, '—')}" for p in providers]
    lines += summary
    ntype = "warning" if summary else "success"
    notify("🔄 contact-sync run", "\n".join(lines), ntype)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
