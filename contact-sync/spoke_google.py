"""Google People API spoke — plan (dry-run) and apply for the initial
convergence, plus the building blocks the ongoing sync reuses.

Auth: GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / GOOGLE_REFRESH_TOKEN from
the environment (sourced from the "Contact Sync Google" Pass item by the
caller — never argv, never files).

Plan semantics for convergence:
  - canonical contact WITH a google source ID  → compare; "update" if the
    canonical fields differ from what Google holds, plus "delete" for any
    extra google IDs beyond the first (intra-provider duplicates that were
    merged into this canonical contact).
  - canonical contact WITHOUT a google source ID → "create".
  - Google contacts not in any canonical contact → impossible by
    construction (every pulled contact entered the merge), so convergence
    never deletes anything it didn't positively merge elsewhere.

Usage:
  python3 spoke_google.py plan  --canonical ~/contact-sync/canonical.json --out plan.json
  python3 spoke_google.py apply --plan plan.json --canonical ~/contact-sync/canonical.json \
      --state ~/contact-sync/state.json
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import normalize  # noqa: E402

PERSON_FIELDS = ("names,emailAddresses,phoneNumbers,addresses,organizations,"
                 "birthdays,biographies,urls,photos,metadata")


def access_token():
    body = urllib.parse.urlencode({
        "client_id": os.environ["GOOGLE_CLIENT_ID"],
        "client_secret": os.environ["GOOGLE_CLIENT_SECRET"],
        "refresh_token": os.environ["GOOGLE_REFRESH_TOKEN"],
        "grant_type": "refresh_token",
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token",
                                 data=body, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["access_token"]


def api(token, method, path, body=None, params=None):
    url = "https://people.googleapis.com/v1" + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    })
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                text = r.read()
                return json.loads(text) if text else {}
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code >= 500:
                time.sleep(2 ** attempt)
                continue
            raise
    raise RuntimeError(f"giving up on {method} {path} after retries")


def pull_all(token):
    people, page_token = [], None
    while True:
        params = {"personFields": PERSON_FIELDS, "pageSize": "1000"}
        if page_token:
            params["pageToken"] = page_token
        d = api(token, "GET", "/people/me/connections", params=params)
        people.extend(d.get("connections", []))
        page_token = d.get("nextPageToken")
        if not page_token:
            break
    return people


def to_person(c):
    """Canonical dict → People API person body (core field set only)."""
    p = {}
    if c["name"] or c["given"] or c["family"]:
        name = {}
        if c["given"]:
            name["givenName"] = c["given"]
        if c["family"]:
            name["familyName"] = c["family"]
        if not name:
            name["unstructuredName"] = c["name"]
        p["names"] = [name]
    if c["emails"]:
        p["emailAddresses"] = [{"value": e} for e in c["emails"]]
    if c["phones"]:
        p["phoneNumbers"] = [{"value": t} for t in c["phones"]]
    if c["org"] or c["title"]:
        org = {}
        if c["org"]:
            org["name"] = c["org"]
        if c["title"]:
            org["title"] = c["title"]
        p["organizations"] = [org]
    if c["notes"]:
        p["biographies"] = [{"value": c["notes"]}]
    if c["birthday"]:
        b = c["birthday"]
        date = {}
        if b.startswith("--"):
            date = {"month": int(b[2:4]), "day": int(b[5:7])}
        elif len(b) == 10:
            date = {"year": int(b[:4]), "month": int(b[5:7]), "day": int(b[8:10])}
        if date:
            p["birthdays"] = [{"date": date}]
    if c["urls"]:
        p["urls"] = [{"value": u} for u in c["urls"]]
    return p


def differs(canon, google_norm):
    """Does the canonical contact materially differ from Google's current
    copy (normalized)? Only fields we own are compared."""
    return (
        sorted(canon["emails"]) != sorted(google_norm["emails"])
        or sorted(canon["phones"]) != sorted(google_norm["phones"])
        or (canon["name"] or "") != (google_norm["name"] or "")
        or (canon["org"] or "") != (google_norm["org"] or "")
        or (canon["title"] or "") != (google_norm["title"] or "")
        or (canon["notes"] or "") != (google_norm["notes"] or "")
        or (canon["birthday"] or "") != (google_norm["birthday"] or "")
    )


def make_plan(canonical_path, out_path):
    token = access_token()
    current_raw = pull_all(token)
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as tf:
        json.dump(current_raw, tf)
        tmp = tf.name
    current = {c["source_id"]: c for c in normalize.from_google(tmp)}
    os.unlink(tmp)
    # etags needed for updates
    etags = {p["resourceName"]: p.get("etag", "") for p in current_raw}

    canonical = json.load(open(canonical_path))
    plan = {"create": [], "update": [], "delete": [], "unchanged": 0}
    for c in canonical:
        if c.get("excluded"):
            continue  # import-artifact husks etc. — never synced anywhere
        ids = c["sources"].get("google", [])
        if not ids:
            plan["create"].append({"uid": c["uid"], "name": c["name"]})
            continue
        survivor = ids[0]
        for dup in ids[1:]:
            plan["delete"].append({"uid": c["uid"], "google_id": dup,
                                   "name": c["name"],
                                   "reason": "intra-google duplicate merged"})
        if survivor in current and differs(c, current[survivor]):
            plan["update"].append({"uid": c["uid"], "google_id": survivor,
                                   "name": c["name"], "etag": etags.get(survivor, "")})
        else:
            plan["unchanged"] += 1
    with open(out_path, "w") as f:
        json.dump(plan, f, indent=1)
    os.chmod(out_path, 0o600)
    print(f"plan: create {len(plan['create'])}, update {len(plan['update'])}, "
          f"delete {len(plan['delete'])} (intra-google dups), unchanged {plan['unchanged']}")
    return plan


def apply_plan(plan_path, canonical_path, state_path):
    token = access_token()
    plan = json.load(open(plan_path))
    canonical = {c["uid"]: c for c in json.load(open(canonical_path))}
    state = json.load(open(state_path))

    created = updated = deleted = failed = 0
    for item in plan["create"]:
        c = canonical[item["uid"]]
        try:
            r = api(token, "POST", "/people:createContact",
                    body=to_person(c), params={"personFields": "names,metadata"})
            new_id = r["resourceName"]
            c["sources"]["google"] = [new_id]
            state["contacts"][c["uid"]]["providers"]["google"] = [new_id]
            created += 1
        except urllib.error.HTTPError as e:
            print(f"CREATE FAILED {item['name']!r}: {e.code} {e.read()[:200]}", file=sys.stderr)
            failed += 1
    for item in plan["update"]:
        c = canonical[item["uid"]]
        body = to_person(c)
        body["etag"] = item["etag"]
        body["resourceName"] = item["google_id"]
        fields = "names,emailAddresses,phoneNumbers,organizations,biographies,birthdays,urls"
        try:
            api(token, "PATCH", "/" + item["google_id"] + ":updateContact",
                body=body, params={"updatePersonFields": fields})
            updated += 1
        except urllib.error.HTTPError as e:
            print(f"UPDATE FAILED {item['name']!r}: {e.code} {e.read()[:200]}", file=sys.stderr)
            failed += 1
    for item in plan["delete"]:
        try:
            api(token, "DELETE", "/" + item["google_id"] + ":deleteContact")
            deleted += 1
        except urllib.error.HTTPError as e:
            if e.code == 404:
                deleted += 1  # already gone — same outcome
            else:
                print(f"DELETE FAILED {item['name']!r}: {e.code} {e.read()[:200]}", file=sys.stderr)
                failed += 1
                continue
        c = canonical[item["uid"]]
        c["sources"]["google"] = [i for i in c["sources"].get("google", []) if i != item["google_id"]]
        state["contacts"][item["uid"]]["providers"]["google"] = c["sources"]["google"]

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
    args = ap.parse_args()
    if args.mode == "plan":
        make_plan(args.canonical, args.out or "google-plan.json")
    else:
        apply_plan(args.plan, args.canonical, args.state)


if __name__ == "__main__":
    main()
