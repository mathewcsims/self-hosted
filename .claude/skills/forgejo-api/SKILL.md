---
name: forgejo-api
description: "Push, pull, or manage repos/issues on Mathew's self-hosted Forgejo instance at https://fj.mathewcsims.uk — a LAN-only git remote for personal projects he doesn't want on a third-party host. Trigger this whenever Mathew asks Claude Code to clone/push/create a repo there, or otherwise interact with 'fj'/Forgejo programmatically. Two credentials exist: the claude-agent bot token (default) and Mathew's own API token (for work under his account) — talk to it directly via git/curl; there is no MCP server for this instance."
---

# Forgejo API + git (fj.mathewcsims.uk)

Direct REST API and git use, no MCP server — same reasoning as the
`bookstack-api` skill: this is Mathew's own infrastructure, and a plain
`curl`/`git`-based skill avoids running a third-party MCP process just to
do what a shell can already do.

**Reachability: LAN/tailnet only.** Same Caddy `remote_ip` gate as every
other LAN-only app in `~/self-hosted/` — this only works from somewhere
with that access (the Mac itself, or the Pi). A hung connection almost
always means this, not an app-level problem.

## Which account to use

There are **two** usable credentials. Default to the bot; reach for
Mathew's own token when the work belongs under his account.

| Credential | Pass item | Field | Acts as |
| --- | --- | --- | --- |
| Bot token (default) | `Forgejo Claude Agent` | `BOT_TOKEN` | `claude-agent`, non-admin |
| Mathew's token | ``Forgejo `mathewcsims` `` | `API_TOKEN` | `mathewcsims`, admin |

**Default to `claude-agent`.** It's a separate non-admin user created
specifically for this — see `~/self-hosted/SETUP.md`'s Forgejo section for
why (bounded blast radius, independent revocation, distinct audit trail
from Mathew's own activity). Use it for anything exploratory or
agent-initiated.

**Use Mathew's own token when the repo should live under `mathewcsims`,**
or when touching a repo he already owns that the bot isn't a collaborator
on. He has explicitly authorised this — it removes the old
create-under-bot-then-transfer dance. Prefer it over asking him to add
`claude-agent` as a collaborator just to make the bot work.

**Never use the "Forgejo" Pass item.** That one holds `ADMIN_USERNAME` /
`ADMIN_PASSWORD` — his web login, not a token. There is no API token in it.

**Finding the items: list the vault, don't substring-search "forgejo".**
Mathew's item was titled "Foregjo `mathewcsims`" (misspelt) for a while, so
a `grep forgejo` over item titles silently missed it entirely and led to a
confident, wrong "no personal token exists". It has since been renamed, but
the lesson stands — enumerate `pass-cli item list` and look, rather than
filtering on a spelling you assumed.

## Credentials

Fetch live from Proton Pass (`Self-Hosted Secrets` vault) — never hardcode
a token or print one to a terminal/log. For the bot, item "Forgejo Claude
Agent", field `BOT_TOKEN`:

```sh
BOT_TOKEN=$(PROTON_PASS_AGENT_REASON="Forgejo agent API/git call" pass-cli item view \
    --vault-name "Self-Hosted Secrets" --item-title "Forgejo Claude Agent" --output json \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
content = d["item"]["content"]["content"]
fields = [f for s in content["Custom"]["sections"] for f in s["section_fields"]]
fields += d["item"]["content"].get("extra_fields", [])
for f in fields:
    if f["name"] == "BOT_TOKEN":
        print(list(f["content"].values())[0])')
```

For Mathew's own account it's the same extraction with the item title and
field name swapped — mind the backticks in the title, which are part of it
and need escaping inside a double-quoted shell string:

```sh
API_TOKEN=$(PROTON_PASS_AGENT_REASON="Forgejo API/git call as Mathew" pass-cli item view \
    --vault-name "Self-Hosted Secrets" --item-title 'Forgejo `mathewcsims`' --output json \
    | python3 -c 'import json,sys
d=json.load(sys.stdin)
content = d["item"]["content"]["content"]
fields = [f for s in content.get("Custom",{}).get("sections",[]) for f in s["section_fields"]]
fields += d["item"]["content"].get("extra_fields", [])
for f in fields:
    if f["name"] == "API_TOKEN":
        print(list(f["content"].values())[0])')
```

Use `.get("Custom",{}).get("sections",[])` rather than indexing
`content["Custom"]["sections"]` directly — the personal item has no
`Custom` key at all, and the unguarded version dies with a `KeyError`
before it ever reaches `extra_fields`.

**Check both `Custom.sections` and `extra_fields`, always** — which one a
given field lands in depends on *how* it was added, not anything about the
field itself: `pass-cli item create --from-template` puts everything under
`content.content.Custom.sections[].section_fields`, but `pass-cli item
update --field X=Y` (used here, since `BOT_TOKEN` was generated and stored
*after* the account already existed) appends to a separate top-level
`content.extra_fields` array instead. A script that only checks
`Custom.sections` will silently find nothing for a field added the second
way — confirmed the hard way when this exact script missed `BOT_TOKEN`
until the extraction was widened to check both.

**The token's scope is deliberately narrow**: `write:repository`,
`write:issue`, `write:user` only — confirmed empirically (not just from
docs, which were incomplete here) that repo creation via `POST
/user/repos` actually requires `write:user` in addition to
`write:repository`, despite what Forgejo's own scope docs imply. No
`admin`/`organization`/`package`/`misc` scope at all — confirmed a request
to `/api/v1/admin/*` returns 401 regardless.

**Zero repo access by default.** The bot account starts with no access to
anything Mathew hasn't explicitly granted. To let it touch an *existing*
repo Mathew owns, he needs to add `claude-agent` as a collaborator first
(Settings → Collaborators, on that repo, in the web UI) — this skill can't
grant that access itself. Repos the bot *creates itself* (under its own
account) are fully usable immediately. Where this would otherwise block,
use Mathew's own token instead of asking him to grant collaborator access.

**A rejected token returns HTTP 500, not 401.** Confirmed empirically on
this instance: a well-formed but unrecognised (revoked/stale) token gives
`500` with an empty `message`, identical to a deliberately bogus one; only
a *missing* `Authorization` header gives `401`. So a 500 from
`/api/v1/user` means "bad token", not "server broken" — check
`/api/v1/version` unauthenticated to confirm the instance itself is
healthy before going looking for an outage.

## API usage

Base URL: `https://fj.mathewcsims.uk/api/v1`. Auth header format is
`Authorization: token <TOKEN>` (not `Bearer`, not `Token id:secret` like
BookStack — Forgejo's own doc calls this "for historical reasons").

```sh
curl -s -H "Authorization: token ${BOT_TOKEN}" https://fj.mathewcsims.uk/api/v1/user
```

- `POST /user/repos` — create a repo under whichever account the token
  belongs to (`{"name": "...", "private": true, "auto_init": true}`).
  Pass `auto_init: false` when pushing an existing local repo.
- `GET /repos/{owner}/{repo}` — read repo metadata
- `POST /repos/{owner}/{repo}/transfer` — change owner
  (`{"new_owner": "mathewcsims"}`). Returns `202`; with Mathew's admin
  token a transfer to himself completes immediately rather than sitting
  pending, and the old path then `301`s to the new one. Useful for
  rehoming something the bot created before you realised it belonged
  under his account.
- `DELETE /repos/{owner}/{repo}` — delete a repo the token's account owns
- `POST /repos/{owner}/{repo}/issues` — file an issue
  (`{"title": "...", "body": "..."}`)
- `GET /repos/search?q=...` — search visible repos

## git over HTTPS

Either token works directly as the git credential — no separate SSH key
needed for HTTPS-based clone/push:

```sh
git clone "https://claude-agent:${BOT_TOKEN}@fj.mathewcsims.uk/claude-agent/<repo>.git"
```

**Prefer a per-command auth header over a token in the remote URL** when
setting up a repo Mathew will keep using. Embedding it in the URL writes
the token into `.git/config` in plaintext, where it persists and leaks into
anything that prints the remote:

```sh
git remote add origin "https://fj.mathewcsims.uk/mathewcsims/<repo>.git"
git -c "http.extraHeader=Authorization: token ${API_TOKEN}" push -u origin main
```

The remote stays clean and Mathew's own credential helper handles his
later pushes. Pipe push/clone output through
`sed "s/${TOKEN}/***/g"` if there's any chance the token appears in it.

Commits made by an agent should use a distinct identity, not Mathew's own
name/email, so activity stays attributable — **even when authenticating
with his token**. Authentication and authorship are separate: acting as
`mathewcsims` to place a repo under his account doesn't make the commits
his work.
```sh
git config user.name "claude-agent"
git config user.email "claude-agent@mathewcsims.uk"
```

## Practical notes

- To work on a repo Mathew already owns, use his own token — or ask him to
  add `claude-agent` as a collaborator. Either way, don't create a
  duplicate under the bot's account as a workaround.
- Prefer creating draft/working repos under the bot's own account for
  anything exploratory or agent-initiated. Anything Mathew asked for by
  name, and expects to own, should go under `mathewcsims` from the start.
- Default repos to `private: true` unless he says otherwise — the whole
  point of this instance is that its contents aren't on a third-party host.
- Watch what `git add -A` sweeps up in a fresh directory. Claude Code will
  drop a `.claude/settings.local.json` in the working directory the first
  time a permission is granted mid-session; it's per-machine state and has
  no business being committed. Add a `.gitignore` before the first commit.
