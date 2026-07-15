---
name: forgejo-api
description: "Push, pull, or manage repos/issues on Mathew's self-hosted Forgejo instance at https://fj.mathewcsims.uk — a LAN-only git remote for personal projects he doesn't want on a third-party host. Trigger this whenever Mathew asks Claude Code to clone/push/create a repo there, or otherwise interact with 'fj'/Forgejo programmatically. Use the claude-agent bot account's scoped token, never his own admin credentials — talk to it directly via git/curl; there is no MCP server for this instance."
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

**Use the bot account, never Mathew's own admin credentials.** Agents
authenticate as `claude-agent`, a separate non-admin Forgejo user created
specifically for this — see `~/self-hosted/SETUP.md`'s Forgejo section for
why (bounded blast radius, independent revocation, distinct audit trail
from Mathew's own activity). Never use the "Forgejo" Pass item (that's
Mathew's personal admin login) — always "Forgejo Claude Agent".

## Credentials

Fetch live from the "Forgejo Claude Agent" Proton Pass item
(`Self-Hosted Secrets` vault), field `BOT_TOKEN` — never hardcode it or
print it to a terminal/log:

```sh
BOT_TOKEN=$(PROTON_PASS_AGENT_REASON="Forgejo agent API/git call" pass-cli item view \
    --vault-name "Self-Hosted Secrets" --item-title "Forgejo Claude Agent" --output json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin)
for s in d["item"]["content"]["content"]["Custom"]["sections"]:
    for f in s["section_fields"]:
        if f["name"]=="BOT_TOKEN": print(list(f["content"].values())[0])')
```

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
account) are fully usable immediately.

## API usage

Base URL: `https://fj.mathewcsims.uk/api/v1`. Auth header format is
`Authorization: token <TOKEN>` (not `Bearer`, not `Token id:secret` like
BookStack — Forgejo's own doc calls this "for historical reasons").

```sh
curl -s -H "Authorization: token ${BOT_TOKEN}" https://fj.mathewcsims.uk/api/v1/user
```

- `POST /user/repos` — create a repo under the bot's own account
  (`{"name": "...", "private": true, "auto_init": true}`)
- `GET /repos/{owner}/{repo}` — read repo metadata
- `DELETE /repos/{owner}/{repo}` — delete a repo the bot owns
- `POST /repos/{owner}/{repo}/issues` — file an issue
  (`{"title": "...", "body": "..."}`)
- `GET /repos/search?q=...` — search repos the bot can see

## git over HTTPS

The token also works directly as the git credential — no separate SSH key
needed for HTTPS-based clone/push:

```sh
git clone "https://claude-agent:${BOT_TOKEN}@fj.mathewcsims.uk/claude-agent/<repo>.git"
```

Commits authored this way should use a distinct identity, not Mathew's own
name/email, so activity is attributable:
```sh
git config user.name "claude-agent"
git config user.email "claude-agent@mathewcsims.uk"
```

## Practical notes

- To work on a repo Mathew already owns, ask him to add `claude-agent` as
  a collaborator on it first — don't try to create a duplicate under the
  bot's own account as a workaround.
- Prefer creating draft/working repos under the bot's own account for
  anything exploratory or agent-initiated; only touch Mathew's own repos
  once he's explicitly granted access.
