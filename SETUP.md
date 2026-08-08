# Self-hosted apps — Mac + Raspberry Pi + slartibartfast + DrayTek

One Raspberry Pi (Caddy) is the shared internet front door for every app below.
Most apps are a podman-compose stack on the Mac; several run on the Pi itself;
one (Immich) runs on a third host, `slartibartfast`, an Ubuntu box. New apps
follow the same recipe — see "Adding another app" near the end.

| App | URL | Runs on | Login |
|-----|-----|---------|-------|
| copyparty | `https://cp.mathewcsims.uk` | Mac `:3923` | `admin` + others, see its section below |
| Memos | `https://prospect-ukri-tus.mathewcsims.uk` | Mac `:5230` | set up on first visit; OAuth planned |
| Ghost blog | `https://blog.mathewcsims.uk` | Mac `:2368` | set up on first visit |
| Fizzy | `https://fizzy.mathewcsims.uk` | Mac `:3600`, LAN-only | magic link / code to `mat@mathewcsims.uk`; signups close after the first account |
| Super Productivity | `https://sp.mathewcsims.uk` | Mac `:3601`, LAN-only | **no login — none exists**; the LAN gate is the whole access control |
| Landing page | `https://mathewcsims.uk` | Mac `:3080` | static site, no login |
| Karakeep | `https://karakeep.mathewcsims.uk` | Mac `:3000` | set up on first visit; signups disabled |
| Apprise API | `https://apprise.mathewcsims.uk` | **Pi**, LAN-only | no login — LAN-gate is the only access control |
| Uptime Kuma | `https://status.mathewcsims.uk` | **Pi** | set up on first visit; 2FA recommended |
| Kopia backups | `https://backup.mathewcsims.uk` | **Pi**, LAN-only (Mac also backs up, no daemon) | username + password, see its section below |
| Immich | `https://immich.mathewcsims.uk` | **slartibartfast** `:2283`, LAN/tailnet-only | local account, no SSO (deliberate — see its section below) |

## Architecture

```
                  your single static public IP
                             │
               DrayTek Vigor2866  (WAN 80/443)
                             │  forwarded to the Pi (10.0.1.19)
                             ▼
       ┌───────────────────────────────────────────────────┐
       │ Raspberry Pi 10.0.1.19                            │
       │ • Caddy: terminates HTTPS (Let's Encrypt, auto)   │
       │ • Routes by hostname to either a Mac app (LAN     │
       │   http) or a Pi-resident compose stack (by        │
       │   container name over `pi-shared` — no host       │
       │   port published):                                │
       │     Mac:    mathewcsims.uk, cp, prospect-ukri-    │
       │             tus, blog, karakeep, owl,             │
       │             fizzy*, sp*,                          │
       │             author*, fj*                          │
       │             (author/fj are BookStack/Forgejo,     │
       │             LAN/tailnet-gated)                    │
       │     Pi:     status (Kuma), apprise*,              │
       │             backup* (Kopia)                       │
       │     slarti: immich*  (third host, 10.0.1.11)      │
       │     router: mc37* (its own admin UI)              │
       │             (* = LAN clients only, WAN aborted)   │
       │ • Refuses any other hostname / bare IP            │
       └──────────────────────────┬────────────────────────┘
                                  │ LAN http (one hop per Mac app)
                                  ▼
                     Mac 10.0.1.14 — one podman-compose
                     stack per app, each its own folder:
                       copyparty  :3923  (data on disk)
                       memos-prospect-ukri-tus  :5230  (sqlite)
                       blog (Ghost)  :2368  (MySQL)
                       landing-page  :3080  (static)
                       karakeep  :3000  (sqlite + Meilisearch)
                       fizzy  :3600  (sqlite)
                       super-productivity  :3601  (static,
                         no data — syncs to copyparty)

                     slartibartfast 10.0.1.11 — Ubuntu box,
                     docker-compose (NOT podman):
                       immich  :2283  (own vector-Postgres +
                         Valkey + ML sidecars; LAN/tailnet only)
```

The Pi is the **single front door** for all apps. Because it owns ports 80/443,
Let's Encrypt validation works normally and public URLs are clean, no ports.
Several apps (Apprise, Uptime Kuma, the Tailscale
webhook relay, Kopia's server) are deliberately Pi-resident rather than
Mac-resident — either
for resilience (the thing telling you something's down shouldn't depend on
the Mac being up) or because they're pure machine-to-machine plumbing with no
reason to cross hosts — see each app's own section below for the (tighter)
networking pattern that comes from Caddy and the app being on the same host.

**Three hosts, two proxy patterns.** Apps on the **Pi itself** are proxied by
container name over the `pi-shared` docker network and publish no ports. Apps
on **any other host** (the Mac, or slartibartfast) must publish a port and be
proxied by IP, via `{$MAC_IP}` / `{$SLARTI_IP}` in the Caddyfile — the
`pi-shared` network doesn't span machines. Adding a fourth host means adding a
third such env var, not a new mechanism.

### File map

`self-hosted/` holds one subfolder per app. Shared, cross-app bits
(`autostart/`, `pi-reverse-proxy/`, `scripts/`, `pf-lockdown/`, this doc) live
at the root. Apps deploy to the **Mac** (`podman compose`) by default; several
deploy to the **Pi** instead (copied over and run with `docker compose`, not
`podman compose` — the Pi runs Docker, not podman); one (Immich) deploys to
**slartibartfast**, a third host, also with `docker compose`. Each app's own
section below says which.

| Path | Runs on | Purpose |
|------|---------|---------|
| `copyparty/compose.yaml` | **Mac** | copyparty only (plain HTTP on the LAN) |
| `copyparty/cfg/copyparty.conf` | **Mac** | volume + permission definitions (no secrets — tracked) |
| `copyparty/cfg/accounts.conf` | **Mac** | **real account passwords — gitignored**; see `accounts.conf.example` |
| `copyparty/data/` | **Mac** | **your private files live here** |
| `copyparty/public/` | **Mac** | anonymous-readable files (`/pub`) |
| `copyparty/inbox/` | **Mac** | password drop-box uploads land here |
| `memos-prospect-ukri-tus/compose.yaml` | **Mac** | Memos, container `memos-prospect-ukri-tus` (plain HTTP on the LAN) |
| `memos-prospect-ukri-tus/data/` | **Mac** | Memos' sqlite DB + attachments |
| `owl/compose.yaml` | **Mac** | Memos, container `owl` — a separate personal instance, closed registration, migrated from a ScaleTail Tailscale-sidecar deployment |
| `owl/data/` | **Mac** | **your notes live here** (sqlite DB + attachments) |
| `owl/owl-logo.svg` | **Mac** | source asset for the instance logo (tracked; the deployed logo itself is a data URI in Memos' own DB) |
| `owl/owl-theme.css` | **Mac** | source stylesheet for the instance accent theme (tracked; deployed via `additionalStyle` in Memos' own DB) |
| `owl/document-viewer/` | **Mac** | client-side attachment preview feature — source (`src/`), esbuild config, and a separate Caddy sidecar (`compose.yaml`, own `Caddyfile`) serving the built bundle; deployed via `scripts/pass-deploy-owl-document-viewer.sh`, see the Owl section below |
| `fizzy/compose.yaml` | **Mac** | Fizzy Kanban backlog; reads secrets from the "Fizzy" **and** "Proton SMTP" Pass items |
| `fizzy/storage/` | **Mac** | **your backlog lives here** — SQLite + uploads |
| `super-productivity/compose.yaml` | **Mac** | static Super Productivity bundle. **No volume, no data** — tasks live in the browser and in copyparty's `/sp-sync` |
| `copyparty/sp-sync/` | **Mac** | **Super Productivity's synced tasks** — the only durable copy |
| `blog/compose.yaml` | **Mac** | Ghost + MySQL + traffic-analytics; reads secrets from Proton Pass |
| `blog/db/` | **Mac** | **Ghost's MySQL datadir** |
| `blog/content/` | **Mac** | **your posts, images, themes live here** |
| `blog/traffic-analytics-data/` | **Mac** | Tinybird-backed analytics data |
| `landing-page/compose.yaml` | **Mac** | static site for the bare apex domain — no secrets, no data dir |
| `karakeep/compose.yaml` | **Mac** | Karakeep + Meilisearch; reads secrets from Proton Pass |
| `karakeep/data/` | **Mac** | **your bookmarks/assets/archives live here** |
| `karakeep/meilisearch-data/` | **Mac** | search index |
| `bookstack/compose.yaml` | **Mac** | BookStack + MariaDB sidecar; LAN-only (`author.mathewcsims.uk`); reads secrets from Proton Pass |
| `bookstack/config/` | **Mac** | **your wiki pages/books/shelves live here** |
| `bookstack/db/` | **Mac** | **BookStack's MariaDB datadir** |
| `forgejo/compose.yaml` | **Mac** | Forgejo (git + issues), SQLite; LAN-only (`fj.mathewcsims.uk`) plus direct git-over-SSH on port 2222; reads secrets from Proton Pass |
| `forgejo/data/` | **Mac** | **your repos, SQLite DB, SSH host keys live here** |
| `docs/compose.yaml` | **Mac** | HedgeDoc — personal Markdown authoring (`docs.mathewcsims.uk`); LAN/tailnet-only *and* per-user login; Postgres sidecar; reads `POSTGRES_PASSWORD` from Proton Pass |
| `docs/pgdata/` | **Mac** | **your notes live here** (HedgeDoc's Postgres datadir) |
| `docs/uploads/` | **Mac** | **every image pasted into a note lives here** — gitignored, so Kopia is the only copy |
| `contact-sync/` | **Mac** | hub-and-spoke contact sync engine (Proton/Google/2× Microsoft) — `sync.py` + per-provider spoke modules; canonical vCard store lives outside the repo at `~/contact-sync/store/` (its own private Forgejo repo); daily launchd job |
| `ntfy/compose.yaml` | **Pi** | self-hosted push notifications, on trial alongside Discord; auth default-deny, fed by Apprise |
| `ntfy/data/` | **Pi** | **auth DB, message cache, attachments live here** |
| `msims-link/compose.yaml` | **Pi** | chhoto-url — self-hosted URL shortener (`msims.link`); reads secrets from Proton Pass |
| `msims-link/data/` | **Pi** | **your short links (SQLite, WAL mode) live here** |
| `msims-link/landing/` | **Pi** | static fallback for the bare domain (Caddy's own redirect normally intercepts before this is ever served — see the msims.link section) |
| `immich/compose.yaml` | **slartibartfast** | Immich photo library — server + ML sidecar + Valkey + Immich's own vector-Postgres; LAN/tailnet-only; reads secrets from Proton Pass |
| `immich/data/` | **slartibartfast** | **your photos and videos live here** (gitignored) — `library/` originals, `upload/`, `profile/`, regenerable `thumbs/`+`encoded-video/`, and `backups/` (Immich's own DB dumps) |
| `immich/pgdata/` | **slartibartfast** | Immich's Postgres datadir (gitignored) — deliberately NOT what gets backed up, see its section |
| `immich/kopia-backup.sh` | **slartibartfast** | daily Kopia backup of everything on that host worth keeping — the photo library, and (since 2026-08-04) a `pg_dump` of LiteLLM's database; alerts via Apprise on failure |
| `immich/kopia-immich.{service,timer}` | **slartibartfast** | systemd **user** units driving the above at 03:00 (installed to `~/.config/systemd/user/`) |
| `scripts/dump-databases.sh` | **Mac** | consistent DB dumps (pg_dump / mysqldump / SQLite `VACUUM INTO`) written before every Kopia run; alerts via Apprise on failure |
| `pi-db-dumps/` | **Pi** | same for Pi-hosted databases — script + systemd **user** timer at 01:30; also triggers its own Kopia snapshot |
| `trivy-scan/scan.py` + `.plist` | **Mac** | weekly launchd job scanning every pinned image in the repo for new CVEs; state lives outside the repo at `~/trivy-scan-state/`, keyed by repository+tag so a digest re-pin does not re-report as new |
| `.github/workflows/ci.yml` | GitHub | required PR checks — dependency vulnerability screening, document-viewer build/audit, Caddyfile validation; enforced by a branch ruleset on `main`, see "Branch protection + required CI" |
| `podman-watchdog/` | **Mac** | dead-man's-switch pinging an Uptime Kuma push monitor every 2 min, and restarting the VM after 2 consecutive failures (capped, cooled down, locked); push token and state live outside the repo at `~/podman-watchdog/` |
| `.claude/skills/bookstack-api/`, `.claude/skills/forgejo-api/` | — | Claude Code skills for talking to those two instances' REST APIs directly (no MCP servers for either) |
| `pi-reverse-proxy/compose.yaml` | **Pi** | Caddy reverse proxy (fronts every app above, plus the LAN-only sites below); also creates the `pi-shared` Docker network |
| `pi-reverse-proxy/Caddyfile` | **Pi** | routing + auto-HTTPS for every hostname |
| `pi-reverse-proxy/.env` | **Pi** | domain, email, Mac IP — gitignored; see `.env.example` |
| `apprise/compose.yaml` | **Pi**, LAN-only | generic Discord notification relay for any script to `curl`; no secrets in the compose file itself |
| `apprise/scripts/seed.py` | **Pi** | no-secrets helper invoked by `scripts/pass-seed-apprise.sh` to register the Discord webhook after deploy |
| `apprise/config/` | **Pi** | **the registered notification-target config lives here** |
| `uptime-kuma/compose.yaml` | **Pi** | uptime monitoring + public status page; no secrets — admin account set up via its own first-visit wizard |
| `uptime-kuma/data/` | **Pi** | **your monitors, history, and settings live here** |
| `kopia-server/compose.yaml` + `Dockerfile` + `entrypoint.sh` | **Pi**, LAN-only | Kopia backup server + web UI; reads secrets merged from the "Kopia" and "Backblaze B2" Proton Pass items |
| `kopia-server/config/`, `cache/`, `logs/`, `tmp/` | **Pi** | Kopia's own local state — repository connection, TLS cert, cache. **Not** where your backed-up data lives (that's in B2) |
| `kopia-mac/backup.sh` + `uk.mathewcsims.kopia-mac-backup.plist` | **Mac** | launchd job (no compose project, no persistent daemon) triggering scheduled Kopia snapshots of the Mac's app data, 02:00 |
| `kopia-mac/mirror-on-connect.sh` + `uk.mathewcsims.kopia-mirror.plist` | **Mac** | launchd job on `WatchPaths /Volumes` — mirrors the B2 bucket to the external drive automatically whenever it is connected; this is the **second copy** for the Pi's and slartibartfast's data |
| `kopia-mac/verify-backups.sh` + `uk.mathewcsims.kopia-verify.plist` | **Mac** | launchd job, 06:00 — verifies every active source on **all three hosts** actually snapshotted cleanly and resolves in B2, then sends the nightly confirmation; weekly deep content check on Sundays |
| `autostart/` | **Mac** | launchd auto-start (all podman containers, every app). The agent plist is tracked here and **must** carry `AbandonProcessGroup` — without it launchd kills the VM this job starts; see the podman-watchdog section |
| `scripts/` | — | deploy tooling that fetches secrets from Proton Pass at deploy time, including `pass-create-kopia-secrets.sh`, `pass-import-b2-credentials.sh`, `pass-import-nas-credentials.sh` (legacy — no job mounts the NAS since 2026-08-04), `pass-deploy-kopia-server.sh`, and the DNS automation `dns-digitalocean.sh` / `dns-nextdns.sh` (see "Automating this" under Part 3 above) |
| `pf-lockdown/` | **Mac** | macOS `pf` firewall rules restricting copyparty's published port to the Pi only, plus SSH Remote Login to the Pi + Tailscale CGNAT range |
| `pi-sshd/` | **Pi** | drop-in `sshd_config.d` file disabling password auth (deployed manually, not via a compose stack) |
| `pi-unattended-upgrades/` | **Pi** | security-only auto-patching config + a daily reboot-required notifier (deployed manually) |
| `pi-fail2ban/` | **Pi** | fail2ban jails (sshd, Caddy-abuse), filters, and ban actions (deployed manually) |

### Known values

| Thing | Value |
|-------|-------|
| Mac LAN IP | `10.0.1.14` |
| Pi LAN IP | `10.0.1.19` |
| slartibartfast LAN IP | `10.0.1.11` (tailnet `100.68.10.65`, SSH user `mathewcsims`) |
| Public/WAN IP | `curl -4 ifconfig.me` (static) |
| NAS ("Eddie") | `eddie.nas` / `10.0.1.12`, SMB — see the Kopia section for the `AppleBackups` share |

Give **the Pi, the Mac, and slartibartfast each a fixed LAN IP** via a DrayTek
DHCP reservation (Part 4) so the forward and proxy config never break.

---

## Secrets management (Proton Pass)

Every app's real secrets live in **Proton Pass**, in a vault named
"Self-Hosted Secrets" (named specifically so it's obvious at a glance
which agent/project a shared vault belongs to, if you end up sharing
others with different agents later) — one custom item per app, each field
named after the env var it holds (e.g. the "Karakeep" item has a
`NEXTAUTH_SECRET` field). Nothing is ever written to a `.env` file
as a persistent artifact; secrets are fetched live at deploy time and
either exported directly into the shell for that one `compose up` call, or
(for the one app that needs an actual config file on disk) rendered fresh
each time.

**Why this exists:** replaces the earlier gitignored-`.env`-per-app model.
Centralizes every credential in one auditable place instead of scattered
plaintext files, and via the Proton Pass CLI's "agent" access model, every
read is logged with a stated reason.

**The agent access model — read-only by design.** This repo's tooling
authenticates as a Proton Pass "agent" via a scoped Personal Access Token
(PAT), not a full account login. Proton's own agent model is deliberately
read-only: agent-flagged PATs can view items but **cannot create, edit, or
delete them**, regardless of the vault's sharing role. This means:

- Only a human, logged into `pass-cli` under their own full account (a
  *different* session directory from the agent's), can create or update
  items in the vault.
- The agent side can only ever *consume* secrets that already exist there.

**Auto-login via `self-hosted/.env`.** A durable, read-only,
`Self-Hosted Secrets`-vault-scoped PAT lives in `SECRET_ACCESS_TOKEN`, in a
gitignored `.env` file at the repo root (not per-app — this is the
credential used to reach every other credential). Every `pass-cli`-based
deploy script checks for an active session first and, if none exists,
logs in automatically using this token — no manual `pass-cli login` step
needed in normal operation. If that token itself is ever revoked or
rotated, update `self-hosted/.env` with a fresh one; the scripts will pick
it up on their next run.

**Creating/updating a secret (you, not the agent):**

```
# Log in under your OWN account, in a separate session dir
export PROTON_PASS_SESSION_DIR="$HOME/.pass-cli-personal"
pass-cli login   # your normal Proton Pass login

# Create a new app's item from its existing .env (key=value pairs → fields)
./scripts/pass-import-env.sh <app-dir>              # e.g. karakeep

# Or for a whole-file secret (currently only copyparty's accounts.conf)
./scripts/pass-import-file.sh <file> <item-title> <field-name>
```

**Deploying an app (the agent side, day to day):**

```
# Mac-hosted apps (blog, karakeep, copyparty, landing-page)
./scripts/pass-deploy.sh <app-dir>

# Apps on ANY remote host — the Pi (uptime-kuma, apprise) or
# slartibartfast (immich). Fetches locally, pipes the export +
# `docker compose up -d` over SSH via stdin, so secret values never appear
# in the SSH command line itself. NOTE: it does NOT copy the app folder —
# `scp -r <app-dir> <ssh-host>:<remote-path>` is a separate first step.
./scripts/pass-deploy-remote.sh <app-dir> <ssh-host> <remote-path>

# copyparty specifically: its secret is a whole config file
# (accounts.conf), not env vars, so it needs a render step first, then a
# normal compose up
./scripts/pass-render-file.sh Copyparty ACCOUNTS_CONF copyparty/cfg/accounts.conf
cd copyparty && podman compose up -d
```

**Compose files and `env_file:`.** Every app's `compose.yaml` reads secrets
via plain `${VAR}` interpolation, which podman/docker compose resolves from
already-exported shell variables — exactly what `pass-deploy.sh` sets up
before invoking `compose up`. One exception needed converting: Karakeep
originally used `env_file: - .env`, which requires an actual file to read;
that's now explicit `environment: VAR: ${VAR}` entries instead. If you add
a new app whose upstream compose.yaml uses `env_file:`, convert it the same
way rather than reintroducing a real `.env`.

**The one deliberate exception:** `pi-reverse-proxy/.env` holds
non-secret configuration (`CP_DOMAIN`, `ACME_EMAIL`, `MAC_IP`) rather than
credentials, so it stays as a plain gitignored file — no security benefit
to migrating config values that aren't sensitive.

---

## Part 1 — Mac: copyparty

1. Account passwords live in `copyparty/cfg/accounts.conf` (gitignored — copy
   `accounts.conf.example` to create it if it's missing) — already set. To add
   more users or read-only shares later, edit that file (see comments inside).
2. Start it from `/Users/mathewcsims/self-hosted/copyparty`:
   ```sh
   podman machine start            # if not already running
   cd /Users/mathewcsims/self-hosted/copyparty
   podman compose up -d
   podman compose logs -f copyparty
   ```
3. Confirm it answers on the LAN (from the Mac):
   ```sh
   curl -sI http://localhost:3923/ | head -1      # expect: HTTP/1.1 200 OK
   ```
   Then from the **Pi**, confirm the Pi can reach the Mac:
   ```sh
   curl -sI http://10.0.1.14:3923/ | head -1
   ```
   If that second one fails, see "macOS firewall" below.

> **macOS firewall:** System Settings ▸ Network ▸ Firewall. If on, you may get an
> "allow incoming connections" prompt the first time the Pi connects — click
> Allow. (copyparty still requires a login, so LAN exposure of :3923 is low-risk;
> optionally lock it to the Pi only — see Security notes.)

---

## Part 2 — Raspberry Pi: Caddy reverse proxy

1. Make sure Docker + the compose plugin are installed on the Pi:
   ```sh
   docker --version && docker compose version
   # if missing:  curl -fsSL https://get.docker.com | sh  &&  sudo usermod -aG docker $USER  (re-login)
   ```
2. Copy the `pi-reverse-proxy/` folder from the Mac to the Pi:
   ```sh
   # run on the Pi:
   scp -r mathewcsims@10.0.1.14:/Users/mathewcsims/self-hosted/pi-reverse-proxy ~/
   cd ~/pi-reverse-proxy
   ```
3. Check **`.env`** — `MAC_IP=10.0.1.14`, `CP_DOMAIN`, and `ACME_EMAIL` are
   already filled. Nothing to edit unless an IP changes.
4. Bring it up (no cert yet — DNS + router come next). `caddy` is built from
   `./Dockerfile`, not a stock image (it compiles in the `caddy-ratelimit`
   module — see [Security notes](#security-notes-internet-facing) below), so
   the first run compiles Go from source and takes a few minutes on the Pi's
   arm64 CPU:
   ```sh
   docker compose up -d --build
   docker compose logs -f caddy
   ```
   After editing the Dockerfile or Caddyfile later, re-run
   `docker compose up -d --build` (or `docker compose build` then
   `up -d`) — a plain `up -d` reuses the already-built image and won't
   pick up Dockerfile changes.

---

## Part 3 — DNS (at your registrar)

Add an **A** record for **mathewcsims.uk**:

| Type | Host | Value | TTL |
|------|------|-------|-----|
| `A`  | `cp` | your **WAN IP** | 300 |

Verify once propagated (from anywhere):
```sh
dig +short cp.mathewcsims.uk        # must return your WAN IP
```

### Automating this: `scripts/dns-digitalocean.sh` and `scripts/dns-nextdns.sh`

Both the registrar (DigitalOcean, which manages `mathewcsims.uk`'s DNS) and
NextDNS (used as the LAN resolver — see "Accessing from inside your own
LAN" below) have API tokens stored in Proton Pass, letting these two steps
be scripted instead of done by hand in each dashboard for every new app:

- **"Digital Ocean DNS"** Pass item — `DIGITAL_OCEAN_DNS_TOKEN`, a token
  scoped to DNS management. `scripts/dns-digitalocean.sh` manages the
  actual public `A` records:
  ```
  ./scripts/dns-digitalocean.sh list
  ./scripts/dns-digitalocean.sh add <subdomain> <ip>      # e.g. add cp 185.137.221.35
  ./scripts/dns-digitalocean.sh remove <subdomain>
  ```
  DigitalOcean's API takes the record name *relative* to the zone (`cp`,
  not `cp.mathewcsims.uk`; `@` for the bare apex) — confirmed directly
  against the live API, not assumed.

- **"NextDNS"** Pass item — `NEXT_DNS_TOKEN`. `scripts/dns-nextdns.sh`
  manages the LAN rewrites (what this repo used to call "DrayTek LAN DNS,"
  before establishing that it's actually a NextDNS feature — see below):
  ```
  ./scripts/dns-nextdns.sh list
  ./scripts/dns-nextdns.sh add <fqdn> <ip>                # e.g. add cp.mathewcsims.uk 10.0.1.19
  ./scripts/dns-nextdns.sh remove <fqdn>
  ```
  Rewrites aren't in NextDNS's own public API docs (https://nextdns.github.io/api/,
  still marked "beta") at all — confirmed by fetching a live profile object
  directly and finding a real `rewrites` array despite its absence from the
  documented schema. The profile ID is auto-discovered via `GET /profiles`
  each run, so nothing needs hardcoding.

Both scripts fetch their token from Pass and call the API entirely from
within a single Python process (`urllib.request`, not a `curl` subprocess)
so the token never touches an external command's argv. Neither needs a
personal pass-cli session — like the deploy scripts, they auto-login using
`SECRET_ACCESS_TOKEN` from the repo-root `.env` if no session is active.

#### When `dns-digitalocean.sh` returns `HTTP 401: Unable to authenticate you`

Hit on 2026-08-04 while adding the `paperless` record. **This is a dead
token, not a broken script** — and the distinction is worth internalising
because the two look identical from the command line.

Diagnosis, in the order worth doing it:

1. **Check the token is being read at all.** The Pass item holds one field,
   `DIGITAL_OCEAN_DNS_TOKEN`. A renamed or missing field yields an empty
   string, and an empty bearer token also produces a 401 — the same error
   as a revoked one, from a completely different cause. On 2026-08-04 the
   field was present and the value well-formed: `dop_v1_` prefix, 71 chars
   total (the prefix plus 64), no leading or trailing whitespace.
2. **Distinguish 401 from 403.** This matters more than it looks:
   - **403** = the token is real and authenticated, but lacks the scope for
     what you asked. DigitalOcean supports scoped tokens, so a token
     without domain write access reaches the API fine and is refused at the
     specific call. Fix by re-scoping.
   - **401** = the token does not exist server-side at all. Revoked, or
     expired. No amount of re-scoping helps.
3. **Confirm against `/v2/account`**, which needs no special scope — if
   even that returns 401, the token is definitively dead rather than merely
   under-scoped. It did.

**Cause.** DigitalOcean personal access tokens can be created with an
expiry, and an expired token fails exactly this way, silently, with no
warning anywhere in this repo's tooling. Check the Tokens page — an expired
token normally still appears in the list, flagged as such, which confirms it
in seconds. If it is simply absent, it was revoked.

**Fix — note this does NOT involve granting anything to an agent.** The
tooling authenticates as *you*, with a personal access token stored in Pass;
there is nothing in the DigitalOcean UI to "create access for Claude", and
looking for one is a blind alley. Just mint a fresh PAT and update the
existing Pass item:

1. DigitalOcean control panel → **API** (left sidebar, near the bottom) →
   **Tokens** tab → **Generate New Token**.
2. Name it something traceable (e.g. `self-hosted-dns`). For scopes, either
   Full Access or Custom Scopes with **`domain`** read *and* write (create /
   update / delete) — read alone is enough for `list` but will 403 on `add`
   and `remove`.
3. Set the expiry deliberately. "No expiry" avoids silent breakage but never
   rotates; a dated token rotates but will do this again with no warning.
   Either is defensible — what is not defensible is picking one by accident,
   which is how this happened.
4. Update `DIGITAL_OCEAN_DNS_TOKEN` on the **"Digital Ocean DNS"** Pass
   item. Edit the existing field in the Proton Pass UI rather than using
   `pass-cli item update --field`: that CLI path writes into the top-level
   `extra_fields` array instead of the section, leaving the stale value in
   place alongside the new one. Both scripts read sections *then*
   `extra_fields`, so the new value does win — but a Pass item holding two
   copies of the same credential, one of them dead, is a trap for later.
5. Verify: `./scripts/dns-digitalocean.sh list` should print the zone's
   records.

The same failure mode applies to the NextDNS token in exactly the same way.

NextDNS's API sits behind Cloudflare, which 403s (error 1010) against
Python's default `urllib` User-Agent — worth knowing if you ever see that
specific error from a modified version of this script; a plain identifying
`User-Agent` header clears it.

---

## Part 4 — DrayTek Vigor2866

Log into the router UI — on your `10.0.1.x` LAN the DrayTek is at its gateway IP,
almost certainly `https://10.0.1.1` (check with `route -n get default` on the Mac
if unsure).

### 4a. Reserve fixed IPs for the Pi and Mac
**LAN ▸ Bind IP to MAC** → enable → bind the Pi to `10.0.1.19` and the Mac to
`10.0.1.14` (select them from the table by MAC address). This stops DHCP from
ever moving them.

### 4b. Make sure the router isn't holding 80/443 itself
**System Maintenance ▸ Management** → under *Internet Access Control* /
*Management Port Setup*, ensure **HTTP (80) and HTTPS (443) access from the
Internet (WAN) is unchecked**. If you manage the router remotely, move its
management to another port (e.g. 8443) — otherwise the router answers 443
instead of forwarding it. LAN management can stay on 443.

### 4c. Point WAN 80/443 at the Pi
**NAT ▸ Port Redirection.** Edit your existing 80 and 443 entries (or add two)
so the *Private IP* is the **Pi**:

| Enable | Mode | Service | Protocol | Public Port | Source IP | Private IP | Private Port |
|--------|------|---------|----------|-------------|-----------|------------|--------------|
| ✔ | Single | http  | TCP | 80  | Any | `10.0.1.19` (Pi) | 80  |
| ✔ | Single | https | TCP | 443 | Any | `10.0.1.19` (Pi) | 443 |

Click **OK** on each to apply. (If your old rules were under *NAT ▸ Open Ports*
instead, edit the Local Computer IP there to the Pi.)

> The Vigor2866 supports NAT loopback, so internal devices can usually reach the
> public hostname too — but test from outside (Part 5) to be sure.

---

## Part 5 — Bring-up order & testing

1. ✅ Mac copyparty up (Part 1) and reachable from the Pi.
2. ✅ Pi Caddy up (Part 2).
3. ✅ DNS `cp` A-record resolves to your WAN IP (Part 3).
4. ✅ Router pointed at the Pi (Part 4).
5. Watch the Pi obtain the cert:
   ```sh
   docker compose logs -f caddy      # look for "certificate obtained successfully"
   ```
6. **Test from mobile data (off your Wi-Fi):** open `https://cp.mathewcsims.uk`
   → valid padlock + copyparty login. Log in as `admin`.
7. Upload a file and confirm on the Mac:
   ```sh
   ls -la copyparty/data
   ```

If the cert never issues: DNS hasn't propagated, the router still points at the
old target, or the router is grabbing 443 (recheck 4b).

---

## Public vs private files

- **Private (default):** everything in `copyparty/data/` is served at the root
  `https://cp.mathewcsims.uk/` and needs your `admin` login. Anonymous visitors
  hitting `/` are denied.
- **Public (read-only):** anything in `copyparty/public/` is served at
  `https://cp.mathewcsims.uk/pub` to anyone, no login — **view and download
  only**; they cannot upload, rename, or delete.

**To publish something:** drop a file/folder into `copyparty/public/` (or, logged
in as admin, upload into the `/pub` area in the web UI). **To un-publish:** remove
it. The `welcome.txt` placeholder there can be deleted.

**To expose another existing folder** without moving it, add a volume block to
`copyparty/cfg/copyparty.conf` and run `podman compose restart copyparty`
(restart, not `up -d` — see Troubleshooting):

    [/photos]            # https://cp.mathewcsims.uk/photos
      /w/holiday-2026    # a sub-path of your private data; this makes ONLY it public
      accs:
        r: *             # anonymous read
        A: admin         # you keep full control

(If the folder isn't already inside a mounted path, add it to `compose.yaml`
`volumes:` first, like the `/pub` line.)

### Share links (selective, secret URLs)

Enabled via `shr: /share` + `shr-site` in the config. Logged in as admin, select
any file/folder (public **or** private), click **Share**, optionally set an
expiry/password, and copy the `https://cp.mathewcsims.uk/share/<token>` link. The
recipient needs no login; the token is the access. Manage/revoke from the same
Share area. Shares persist in `copyparty/cfg/copyparty/shares.db`. This is
independent of `/pub` — both work at once.

### Drop box / inbox (password upload, write-only)

`https://cp.mathewcsims.uk/inbox` is a **write-only** drop box backed by
`copyparty/inbox/`. The shared `inbox` account (password in
`copyparty/cfg/accounts.conf`) can **upload** but cannot list or download
anything there — not other people's files, not its own. Only `admin` can see and
retrieve what's been dropped; anonymous visitors (no password) can't upload at
all. Give the inbox password to anyone you want to receive files from; change it
any time in the config (then `podman compose restart copyparty`). The
permissions are `w: inbox` + `A: admin` on the `[/inbox]` volume.

---

## Accessing from inside your own LAN (split DNS)

From *outside* (mobile data) `https://cp.mathewcsims.uk` goes WAN IP → router →
Pi and just works. From *inside* your LAN it may time out, since NAT hairpin
support varies by router and hasn't been reliably established one way or the
other here. Regardless of whether hairpin works, it's worth avoiding the
round-trip anyway — two devices on the same network shouldn't need to go out
to the WAN and back. Cleanest way — make the name resolve straight to the Pi
for LAN clients:

**NextDNS rewrite** (not a DrayTek feature — this repo previously
mis-described this as "DrayTek LAN DNS," which was never actually in use):
add a rewrite for `cp.mathewcsims.uk` → `10.0.1.19` (the Pi) in your NextDNS
configuration.

Now LAN devices (using NextDNS as their resolver) reach the Pi directly (valid
cert, no router round-trip), while the outside world still uses the public IP.
Access control for LAN-only apps in this repo is never based on this DNS
behavior — it's Caddy's own `remote_ip private_ranges` check against the
real source IP of the connection, which holds regardless of how the client
resolved the hostname.

---

## Accessing LAN-only apps over Tailscale

The Pi runs Tailscale, configured as both a subnet router (advertising the
LAN) and an exit node — meaning devices elsewhere can reach this network
through it, including while off any physical LAN entirely. Every LAN-gated
app in this repo (`mc37`, `apprise`, `backup`, `author`,
`paperless`, `fj`, `docs`)
needs **three** separate things to actually be reachable this way. Each is
necessary and none is sufficient, which is what makes this so awkward to
debug: with any one missing, every check you can run on the server comes
back clean.

1. **Caddy has to trust the connection's source IP.** Every LAN-gated block
   uses `@lan remote_ip private_ranges 100.64.0.0/10` — the appended CIDR is
   Tailscale's own address range for every device on a tailnet. Caddy's
   built-in `private_ranges` shortcut does **not** include this (confirmed
   directly from Caddy's own source — it's just the standard RFC1918 ranges
   plus loopback), so without this addition, a tailnet-sourced connection
   was always rejected here regardless of anything else.

2. **The hostname has to actually resolve to the Pi's LAN IP while
   tailnet-connected**, not the public IP — otherwise the request just goes
   out to the internet and back in through the router like any other WAN
   client, and gets the same "closed connection" as anyone else. This is a
   [Tailscale DNS](https://tailscale.com/kb/1054/dns) setting, not something
   this repo configures directly. One specific trap worth knowing:
   Tailscale's **split DNS** (per-domain nameserver overrides) is ignored by
   default on devices using an exit node — only a **global** nameserver
   (applied to all DNS queries, not tied to one domain) reliably applies
   regardless of exit-node use. If DNS resolution for these hostnames is
   handled by a global nameserver that already returns LAN IPs for private
   subdomains (rather than a per-domain split-DNS rule), this works
   correctly without any further Tailscale-side configuration.

3. **The tailnet ACL has to grant the LAN subnet as a destination, by CIDR.**
   This is the one that is easiest to miss, because three *other* things look
   like they cover it and none of them does. The Pi advertising
   `10.0.1.0/24`, that route being approved in the admin console, and the
   client having "use subnet routes" enabled are all necessary — and all
   three can be true while the traffic is still dropped. A subnet route is a
   **separate ACL destination** from the tailnet IPs of the devices; a grant
   like `tag:personal → tag:personal` covers `100.x` addresses only and says
   nothing about the LAN behind a subnet router. The policy file needs an
   explicit grant:

   ```json
   { "src": ["tag:personal"], "dst": ["10.0.1.0/24"], "ip": ["*"] }
   ```

   Manage the policy with `./scripts/tailscale-acl.sh get|put` (validates
   before applying, and sends `If-Match` so a concurrent console edit is a
   412 rather than a silent clobber).

   To check this directly rather than guessing, dump the Pi's own view of
   the enforced filter — it is the receiving node that drops the packets:

   ```bash
   ssh mathew@babel 'sudo tailscale debug netmap' | grep -A2 '"Net": "10\.'
   ```

   If `10.0.1.0/24` is absent, this is the fault. The symptom without it is
   confusing enough to be worth recording: with an exit node the connection
   *times out* (Tailscale deliberately keeps RFC1918 destinations off the
   exit path, so the packet leaves via the local interface and dies), and
   without one it is *refused* (the browser falls back to the public A
   record, reaches Caddy from the internet, and hits `handle { abort }`).
   Neither symptom points at an ACL, and neither leaves any trace on the Pi
   — a full `tcpdump` of the client's traffic shows no connection attempt
   toward the LAN address at all.

   `tcpdump` is **not** installed on the Pi (`sudo apt-get install -y
   tcpdump` if needed, and remove it again afterwards). Worth knowing before
   you write a capture command and get a silent `timeout` failure with an
   empty output file, as happened here. When capturing, watch the interface
   column: tailnet traffic arrives on `tailscale0` from a `100.x` source,
   while anything arriving on `eth0` came in off the internet — that
   distinction is what identifies this class of fault.

Diagnosed 2026-08-06, when `docs.mathewcsims.uk` was unreachable from an
Android client on mobile data. Items 1 and 2 had been in place for months
and item 3 never had been — so despite this section previously claiming the
arrangement was "confirmed working end-to-end", no LAN-gated app had ever
actually been reachable from a genuinely off-LAN tailnet device. Anything
tested from a device sitting on the physical LAN at the time would have
passed regardless, which is how it went unnoticed.

---

## Router admin via mc37.mathewcsims.uk (LAN-only)

A second Caddy site proxies `https://mc37.mathewcsims.uk` → the DrayTek admin at
`https://10.0.1.1:8443`, but **only for private/LAN source IPs** (a
`remote_ip private_ranges` guard) — internet clients are dropped. To make it work:

1. **Public A record** (registrar): `mc37` → your WAN IP. Needed only so Caddy
   can obtain a Let's Encrypt cert; actual access is still blocked to non-LAN.
2. **NextDNS rewrite**: `mc37.mathewcsims.uk` → `10.0.1.19`. This makes LAN
   devices reach the Pi directly, so their source IP is private and passes the
   guard. (Devices must be using NextDNS as their resolver for this to apply —
   this is a NextDNS-level rewrite, not a DrayTek router feature, despite the
   name of this section's original heading; corrected after testing showed the
   DrayTek's own "LAN DNS" feature was never actually in use here.)
3. Copy the updated `Caddyfile` to the Pi and `docker compose restart caddy`.

The admin site's hostname (`mc37.mathewcsims.uk`) and backend (`10.0.1.1:8443`)
are **hardcoded** in `pi-reverse-proxy/Caddyfile`, not env vars — an empty env
var there expands to a keyless `{ }` block that crashes Caddy on startup
(`server block without any key … must be first`). Note: router admin UIs don't
always proxy cleanly (absolute redirects, hardcoded host) — if the DrayTek login
misbehaves, tell me and we'll add a `header_up Host` tweak.

---

## Memos (https://prospect-ukri-tus.mathewcsims.uk)

[Memos](https://github.com/usememos/memos) note-taking app, same architecture as
copyparty: runs on the Mac in `memos-prospect-ukri-tus/`, plain HTTP, fronted by the Pi's Caddy for
TLS + the public hostname. Container is named `memos-prospect-ukri-tus` (not `memos`) to
stay distinct from an unrelated pre-existing Memos stack on this Mac.

**To bring it up (mirrors copyparty's Parts 1–5):**
1. **Mac:** `cd memos-prospect-ukri-tus && podman compose up -d` — starts on `10.0.1.14:5230`.
2. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
3. **DNS** (registrar): add `A` record `prospect-ukri-tus` → your WAN IP.
4. **NextDNS rewrite**: add
   `prospect-ukri-tus.mathewcsims.uk` → `10.0.1.19`, so LAN devices resolve
   straight to the Pi (same reasoning as the `cp` entry below).
5. Watch `docker compose logs -f caddy` on the Pi for the cert, then visit
   `https://prospect-ukri-tus.mathewcsims.uk` to do Memos' first-run setup.

**OAuth / SSO, set up later in the Memos admin UI:** nothing further is needed
in Caddy or the router for this to work.
- `memos-prospect-ukri-tus/compose.yaml` sets `MEMOS_INSTANCE_URL: https://prospect-ukri-tus.mathewcsims.uk`
  — Memos uses this (not the internal Mac address) to build its OAuth callback
  URL, so redirects come back to the real public domain.
- Caddy's `reverse_proxy` already forwards `Host`, `X-Forwarded-For`, and
  `X-Forwarded-Proto` by default — Memos needs no extra headers beyond that.
- When you register the OAuth application with your provider, its callback/
  redirect URL is **`https://prospect-ukri-tus.mathewcsims.uk/auth/callback`**.
- If you ever change the domain, update `MEMOS_INSTANCE_URL` too (then
  `podman compose up -d` in `memos-prospect-ukri-tus/` — compose spec changes need `up -d`, not
  `restart`, to reload environment values).

**Branding (title + logo/favicon):** set via Memos' API, not the container.
`generalSetting.customProfile.logoUrl` drives **both** the browser-tab favicon
and the in-app header logo (Memos only has one field for both, swapped in
client-side JS on page load) — it needs to be loadable **without login**, since
the login screen itself needs it too.

It's set as a **data URI** (`data:image/png;base64,...`) — the image bytes live
directly inside Memos' own settings row, so there's no external URL, no
dependency on `copyparty` or anything else staying up, and no auth concern
(unlike uploading it as a Memos attachment, which requires login to view when
unlinked to a memo). The source PNG lives at `memos-prospect-ukri-tus/prospect-logo-square.png`
— the original `prospect-social-400px.png` was a circle on transparency that
left mismatched empty corners inside Memos' rounded-square logo slot, so it was
squared up (same colours, pie-slice pattern extended out to the corners) before
encoding.

To change it later:
```sh
B64=$(base64 -i memos-prospect-ukri-tus/prospect-logo-square.png | tr -d '\n')
python3 -c "
import json
print(json.dumps({
  'name': 'instance/settings/GENERAL',
  'generalSetting': {'customProfile': {
    'title': 'Mathew'\''s Prospect-UKRI-TUS Notes',
    'logoUrl': 'data:image/png;base64,$B64'
  }}
}))" > /tmp/patch_body.json

curl -X PATCH -H "Authorization: Bearer <a Personal Access Token>" \
  -H "Content-Type: application/json" \
  "http://10.0.1.14:5230/api/v1/instance/settings/GENERAL?updateMask=generalSetting.customProfile.title,generalSetting.customProfile.logoUrl" \
  --data-binary @/tmp/patch_body.json
```
Generate a token yourself in the web UI: Settings ▸ My Account ▸ Access Tokens.

**Hardening:** public self-registration is **deliberate** here (Prospect
members should be able to sign up freely) and must stay on — nothing below
disables it.
- Image pinned to the exact digest behind `:stable` (currently v0.29.1), same
  discipline as every other app here. Checked against usememos/memos's GitHub
  security advisories: several real CVEs exist in its history (an SSRF via
  link-preview fetching, stale auth tokens surviving a password change, a
  CORS misconfiguration, an older SSRF+XSS pair in a since-removed endpoint)
  but all were fixed well before 0.29.1 — nothing unpatched applies.
  `MEMOS_DEMO: "false"` made explicit too (already the default when unset —
  demo mode uses a hardcoded JWT secret instead of a real random one).
- Memos has **no rate-limiting, brute-force lockout, or CAPTCHA of its own
  anywhere in its source** (confirmed by reading it) — same gap class as
  Nimbus. Unlike Nimbus, blanket-limiting all of `/api/v1/auth/*` isn't right
  here since registration must stay easy for real new members. Two
  purpose-matched Caddy zones instead (`pi-reverse-proxy/Caddyfile`):
  - `/api/v1/auth/signin` + `/api/v1/auth/refresh`: 20 requests/min/IP —
    blunts credential-stuffing against existing accounts.
  - `POST /api/v1/users` only (the signup endpoint — method-scoped so it
    doesn't touch authenticated `GET /api/v1/users/*` calls): 5 requests/
    min/IP — generous for a genuine one-off signup, tight against scripted
    mass-registration spam.
  - `/api/v1/auth/me` (the SPA's routine per-page-load session check) is
    deliberately *not* in either zone — it fires constantly during normal
    use and would false-positive.
  - Verified live: 25 rapid signin POSTs → 20 real responses then 429s; 8
    rapid registration POSTs → 5 real responses then 429s, independently of
    the signin zone; GETs to `/api/v1/users/*` unaffected by the
    registration zone's method scoping.

---

## Owl (https://owl.mathewcsims.uk)

A second, unrelated Memos instance (personal notes, not Prospect), same
image/architecture as the section above — but with two real differences:
registration is **closed** here (personal instance, matching the Nimbus
precedent, not the "open for Prospect members" reasoning above), and this
instance's data and OIDC config were **migrated** from a pre-existing
deployment rather than starting fresh.

**Where it came from.** Previously ran as `app-owl` + `tailscale-owl`, a
Tailscale-sidecar pair from an unrelated template repo
(`~/ScaleTail/services/owl/`), reachable only over the tailnet via Tailscale
Serve — never through this repo's Caddy at all. Brought into this repo's
standard managed-app pattern (same shape as the Karakeep migration, which
started the same way) rather than bridging Caddy across the tailnet to a
remote peer — investigation found "owl" wasn't actually a separate machine
in the first place, just a container already running on this same Mac.

**Migration gotcha, worth knowing if this ever comes up again:** the old
deployment's compose file bind-mounted `./owl-data:/var/opt/owl` — a
template bug (Memos' real data path is `/var/opt/memos`, not `/var/opt/owl`).
That bind mount was always empty. The real data (SQLite DB + attachments +
thumbnail cache) was sitting in an anonymous Podman volume Memos itself
auto-created (via its image's own `VOLUME` declaration), found via `podman
inspect <container> --format '{{json .Mounts}}'`. Copied out via a
throwaway container rather than reaching into the podman-machine VM's raw
filesystem directly:
```sh
podman run --rm \
  -v <old-volume-id>:/from \
  -v "$PWD/owl/data":/to \
  alpine sh -c "cp -a /from/. /to/"
```

**OIDC/SSO migrated automatically — only the IdP's registered redirect URI
needed updating.** Memos' OAuth config lives entirely in its own SQLite DB
(confirmed by reading `server/router/api/v1/idp_service.go` — there is no
compose-env-var equivalent, unlike Nimbus's `OIDC_ISSUER_URL`/etc.), so the
existing Infomaniak IdP entry (client ID, secret, authorize/token/userinfo
endpoints) came along with the data copy, untouched. The only thing that
needed changing was the redirect URI registered on **Infomaniak's own
IK-AUTH console** — Memos always computes this client-side as
`https://<domain>/auth/callback` (not configurable, confirmed from
`web/src/pages/AuthCallback.tsx`), so it had to be updated there to
`https://owl.mathewcsims.uk/auth/callback` to match the new domain.

**`MEMOS_INSTANCE_URL` matters beyond just OAuth** — confirmed from
`server/cors.go`: Memos rejects API requests whose `Origin` doesn't exactly
match this value. Get it wrong after a domain change and the whole UI
breaks (CORS-rejected), not just SSO login. Also feeds `robots.txt`/sitemap
generation and email notification links.

**Self-registration closed** — verified in the admin UI
(`generalSetting.disallowUserRegistration`) after deployment, since it
migrated from an instance that could have had it in either state.
**Gotcha found the hard way:** `PATCH /api/v1/instance/settings/GENERAL`
does *not* do a true partial merge respecting `updateMask` the way a
well-behaved field-mask API should — setting only
`customProfile.title`/`customProfile.logoUrl` in one call left
`disallowUserRegistration` reset to its `false` zero-value. Always re-check
the *other* settings after any PATCH to this endpoint, not just the fields
you intended to change.

**Branding:** same data-URI `logoUrl` recipe as the Prospect Memos instance
above (see that section for the full mechanism and the PATCH command
shape) — source SVG lives at `owl/owl-logo.svg`, a simple flat-style owl
icon generated for this instance specifically, encoded directly as an
`image/svg+xml` data URI (no PNG rasterization needed, unlike the Prospect
logo).

**Hardening:** same image digest as `memos-prospect-ukri-tus` (one CVE
review covers both instances). Only one Caddy rate-limit zone
(`rl_owl_auth`, signin+refresh, 20/min/IP) — no signup zone, since
registration is closed here.

### Per-instance theming (both Owl and Prospect)

Memos only ships three built-in themes (light/dark/paper) — not enough to
tell two instances apart at a glance. Rather than a Caddy-injected
stylesheet (fragile — depends on Memos' internal CSS class names staying
stable across releases), Memos has a **native** admin-only hook for this:
`generalSetting.additionalStyle` (Settings ▸ System ▸ "Additional style" in
the admin UI, or via API/`memos-api` skill) — raw CSS, injected as a
`<style>` tag appended to `<body>` on every page load, DB-backed like the
logo/title. There's a matching `additionalScript` field for raw JS too
(unused here).

The three built-in themes are just CSS custom properties on `:root`
(`--primary`, `--sidebar`, `--accent`, etc., all `oklch(...)` values —
exact set and current values confirmed by reading
`web/src/themes/{default,default-dark,paper}.css` at the pinned tag), and
Memos tags `<html>` with `data-theme="<theme>"` when a non-default theme is
selected. So each instance's stylesheet scopes its overrides per theme
(`html[data-theme="default-dark"] { ... }`, etc., with a bare `:root` block
as the light-theme fallback since Memos doesn't tag the default theme
itself) — the accent colors stay correct and legible whichever of the
three built-in themes the *user* has personally selected.

Colors were picked to complement each instance's existing logo (sampled
the actual logo files for exact hex values), overriding only
`--primary`/`--primary-foreground`/`--ring`/`--accent`/`--accent-foreground`/
`--sidebar`/`--sidebar-foreground`/`--sidebar-accent`/`--sidebar-accent-foreground`
— never `--background`/`--foreground`, to avoid touching each built-in
theme's own core legibility handling. Every foreground/background pairing
was checked against WCAG 2.1 contrast ratios before shipping (target ≥4.5:1
for normal text; a couple of `--primary`/`--primary-foreground` pairs
needed darkening from the initial pick to clear that bar). Source
stylesheets, kept for reference: `owl/owl-theme.css` (deep purple +
warm amber, from the owl logo) and
`memos-prospect-ukri-tus/prospect-theme.css` (union green + gold, from the
Prospect logo).

Beyond just the accent palette, three more small touches per instance,
added afterwards for more visual distinctiveness without making either
instance look busy or straying from Memos' own visual language (no
background textures/gradients, no external web fonts — those would mean
pulling from a third-party CDN, cutting against this repo's no-external-
dependency posture):
- **`--radius`** — Owl rounder (0.75rem, a cozier feel), Prospect crisper
  (0.3rem, a more structured/organizational feel) than Memos' 0.5rem
  default. A brand-identity choice, not a per-theme contrast concern, so
  it's declared once (unscoped) rather than duplicated across the three
  `data-theme` blocks — the normal CSS cascade means an unscoped `:root`
  declaration still applies even when a `data-theme`-scoped block is
  active, as long as that block doesn't redeclare the same property.
- **`--shadow-*`** — re-tinted from Memos' neutral black (or paper
  theme's warm brown) to a faint purple-black (Owl) / green-black
  (Prospect), same offset/blur/opacity structure as upstream's own tiers,
  just a hue shift. Also unscoped, and — since this stylesheet is
  injected into `<body>`, always after Memos' own theme `<style>` tag in
  `<head>` in document order — it wins regardless of which of the three
  themes is currently selected.
- **Selection highlight and scrollbar thumb color** — `::selection` and
  `scrollbar-color`/`::-webkit-scrollbar-thumb` reference `var(--primary)`/
  `var(--sidebar-accent)` directly rather than hardcoded colors, so they
  automatically track whichever theme (light/dark/paper) is currently
  active with zero per-theme duplication.

**Gotcha, hit live while doing this:** `instance setting-update`'s `--set`
flag does **not** auto-merge for this endpoint the way it does for
memo/user/shortcut updates — sending only `--set
generalSetting.additionalStyle=...` blanked `disallowUserRegistration`,
`disallowPasswordAuth`, and `customProfile` (title+logo) back to their zero
values on the first attempt against Owl (caught and fixed immediately by
re-sending the full object; same root cause as the earlier
non-partial-merge gotcha documented above, now confirmed to affect the CLI
wrapper too, not just a hand-rolled PATCH). Fixed properly for Prospect by
fetching the full current `GENERAL` setting first, changing only
`additionalStyle` in the parsed JSON, and PATCHing the complete object back
(`raw PATCH ... --body-file`) — the safe pattern this doc already
recommends elsewhere for this endpoint.

### Document viewer (client-side, no conversion pipeline)

Memos' own frontend force-downloads every non-image/video/audio attachment
(`web/src/components/MemoMetadata/Attachment/AttachmentListView.tsx`'s
`DocsList`, confirmed by reading Memos' actual source at the pinned
version: `<a href=... download>` unconditionally wraps every document
attachment). `owl/document-viewer/` adds a client-side preview feature for
PDF/HTML/DOCX/XLSX and a "text family" (Markdown/CSV/JSON/XML/source code)
at high confidence, plus PPTX/EPUB/RTF/OpenDocument/ZIP-TAR-listing at a
deliberately lower-confidence "experimental" tier — with iWork
(.pages/.numbers/.key) and legacy binary Office (.doc/.xls/.ppt) staying
untouched download-only, since no viable client-side renderer exists for
either.

**Why not a conversion pipeline (e.g. LibreOffice/Gotenberg converting
DOCX→PDF before display):** explicitly rejected — every format renders
via its own native, format-preserving client-side library
(`docx-preview`, `Univer.js` fed by SheetJS-CE-parsed cell data,
`pptx-preview`, `epubjs`, a minimal RTF parser, custom ODF XML extraction),
never through an intermediate file-format conversion step.

**Build/deploy shape**, the first JS build tooling in this repo:
- `owl/document-viewer/src/` — hand-authored TypeScript (orchestration,
  per-format viewers), bundled by esbuild (`npm run build` →
  `dist/`, gitignored) with `splitting: true` so the always-loaded entry
  chunk (`main.js`, ~7KB) stays tiny — each heavy per-format library only
  loads via dynamic `import()` when a user actually opens that file type.
- **Static serving**: no existing pattern fit (Memos has no
  mounted-static-directory feature; Caddy has never served a repo-tracked
  bundle as a primary route elsewhere in this repo). A small Caddy sidecar
  (`owl/document-viewer/compose.yaml`, plain `file_server` mode,
  `10.0.1.14:5233`) serves `dist/` — reusing Caddy rather than introducing
  a new technology purely for static files. `pi-reverse-proxy/Caddyfile`
  adds one `handle_path /document-viewer/*` route inside Owl's block.
- **Deployment vehicle**: Memos' own native `additionalScript` hook (same
  mechanism as `additionalStyle` above, its first real use) — but it only
  ever holds a two-line bootstrap (`<script src="/document-viewer/main.js">`),
  not the whole bundle, so iterating on viewer internals only ever touches
  the static sidecar, never the settings API. `scripts/pass-deploy-owl-document-viewer.sh`
  runs the build, brings up the sidecar, and (given `OWL_MEMOS_PAT`, a
  token generated in Owl's own Settings ▸ My Account ▸ Access Tokens)
  PATCHes `additionalScript` via `owl/document-viewer/deploy_additional_script.py`
  — which fetches the full `GENERAL` settings object first and diffs every
  *other* field before/after, failing loudly if the non-merging-PATCH
  gotcha above ever recurs.

**Click interception, deliberately narrow**: the injected script targets
the `a[download]` selector and its `download`/`title` attributes — plain,
semantic HTML, far more stable across Memos releases than any internal
React component/class name. A `MutationObserver` re-scans on every DOM
change (Memos is an SPA; attachments load without full page navigation).
Unrecognized types (iWork, legacy binary, anything else) are never
touched — no listener, no attribute, byte-identical to stock Memos.

**Gotchas hit live while wiring this up, worth knowing if this file ever
needs revisiting:**
- **A visible "preview" badge can't just be appended after the row's own
  content.** Memos' `DocumentItem` row is a two-child flex row
  (`justify-between`: an icon+text group, then a `DownloadIcon`) — adding
  a badge as a normal third flex child breaks that distribution
  unpredictably per filename length. The badge is instead
  `position: absolute` *within* the row (which stays completely untouched
  otherwise), floating just left of the download icon without being a
  flex participant or touching Memos' own DOM nodes — verified against
  live rendered coordinates, not guessed from source alone.
- **Reverse-proxied headers don't simply "override."** Memos' own backend
  sets `X-Frame-Options: DENY` on every response, including attachment
  files (`server/router/fileserver/fileserver.go`) — this blocks even
  same-origin framing (PDF preview needs an `<iframe>`). Two Caddy-side
  attempts failed before the fix held: (1) Caddyfile's adapter reorders
  top-level directives by its own fixed precedence, not source order,
  regardless of where an override is written — fixed by wrapping the
  whole block in an explicit `route { }`, which preserves literal
  execution order; (2) even with mutually-exclusive path matchers, a
  plain `header` directive still produced a broken doubled value
  (`SAMEORIGIN, DENY`) — because `reverse_proxy` copies the upstream's
  headers onto the response with `Add`, not `Set`, appending Memos' own
  DENY on top of anything a prior `header` directive pre-set. The fix had
  to move *into* `reverse_proxy` itself via its `header_down`
  sub-directive, which runs after the upstream response is already copied
  in and genuinely replaces the value. All three stages were confirmed via
  `caddy adapt`'s JSON output and a real authenticated browser `fetch()`
  with `cache: 'no-store'` — curl-without-auth alone was misleading here
  (Memos requires auth to serve attachments; an unauthenticated curl just
  404s).
- **HTML attachments need `srcdoc`, not `iframe.src`.** Even with framing
  allowed, Memos serves `.html` attachments with
  `Content-Disposition: attachment` and `Content-Type: application/octet-stream`
  — confirmed live — a deliberate anti-XSS measure (only images/PDF are
  exempted from Memos' own forced-download handling). Pointing an
  iframe's `src` straight at that URL makes the browser attempt a
  download instead of rendering it, leaving the frame blank. `html.ts`'s
  `renderHtml` instead `fetch()`s the body and injects it via
  `iframe.srcdoc` — this sidesteps `Content-Disposition`/`Content-Type`
  entirely (neither governs `fetch()` reads or `srcdoc` interpretation),
  and the `sandbox="allow-popups"` attribute (deliberately *without*
  `allow-scripts` or `allow-same-origin`, so untrusted uploaded HTML can't
  execute script or reach Owl's session) still applies identically.
- **The Mac's podman-machine bind mount can serve a stale view of
  `dist/`.** More than once during iteration, the sidecar container kept
  serving an old build after a fresh `npm run build` even with the
  `./dist:/srv:ro` bind mount unchanged — confirmed by diffing the
  container's own `/srv/main.js` against the host file, different
  `Last-Modified` timestamps for supposedly the same path. A full
  `podman compose down && podman compose up -d` (not just `restart`)
  reliably picks up the fresh files; a plain `restart` did not. Also
  cache-bust the PDF/HTML iframe's own request (`?_dv=<timestamp>`) so a
  browser that cached an earlier broken response for that exact
  attachment URL — from before any of the fixes above — can't keep
  serving it back silently.

**Fragility surface for future Memos version bumps**: the only real
coupling to Memos internals is the `a[download]` selector and its
`download`/`title` attributes, plus reading `X-Frame-Options`/
`Content-Disposition` behavior off the live server (not assumed) —
smoke-test one attachment per format after any future Memos upgrade.

---

## Marque (https://marque.mathewcsims.uk) — DECOMMISSIONED

> **DECOMMISSIONED 2026-08-04.** Torn down for lack of use (2 memos, 1
> user). Containers, images, volumes, networks, the Caddy site block, the
> Uptime Kuma monitor and the DNS records are all gone; `marque/` was
> removed from this repo and survives only in git history. The section below
> is kept verbatim as the rebuild recipe. A final database dump and a cold
> `tar.gz` of the whole data directory live in `db-dumps/decommissioned/` on
> the Mac, and the **Marque** Proton Pass item was deliberately retained —
> between them, everything needed to stand this back up still exists.


A third, unrelated Memos instance — a private, work-focused notes space.
Unlike Owl, this was a **fresh instance**, not a migration: name chosen from
a separate naming-brainstorm discussion ("letters of marque" — an
officially-authorized private mark), same closed-registration/
Infomaniak-SSO-only pattern as Owl, same pinned image digest as the other
two (one CVE review covers all three).

**Logo/branding:** a wax-seal-and-monogram mark (navy background, brass
ring, oxblood seal face, brass "M" stamped monogram) — designed to evoke
the "official private authorization" concept behind the name, and to sit
clearly apart from Owl's purple/amber owl and Prospect's green/gold leaf
at a glance. Source at `marque/marque-logo.svg`, set via the same
data-URI `logoUrl` recipe as the other two instances.

**Theme:** same per-instance-accent treatment as Owl/Prospect (see that
section above for the full mechanism) — navy/brass/oxblood palette
sampled from the logo, WCAG-contrast-checked, plus the radius/shadow/
selection polish. Marque's `--radius` is `0.15rem` (near-square, a
stamped/official-document feel) — a third distinct value alongside Owl's
0.75rem (rounder) and Prospect's 0.3rem (crisper). Source at
`marque/marque-theme.css`.

### OIDC setup — how Memos actually links an SSO login to a local account

This mattered enough to get wrong on the first instinct that it's worth
documenting precisely, since Owl inherited its OIDC config via data
migration and never exercised this path fresh. Confirmed by reading
`server/router/api/v1/auth_service.go` and `user_service.go` at the pinned
tag:

- **Memos does NOT match SSO logins to local accounts by email.** It uses
  a separate `user_identity` table keyed on `(provider, extern_uid)`
  (`extern_uid` = whatever the IdP's `fieldMapping.identifier` maps to,
  `email` here). Looking this up is the *only* way an SSO login resolves
  to a user — the local `users.email` column is never consulted for
  matching, only populated as a display field when a user is first
  created.
- **A bare "Sign in with Infomaniak" click, with no prior linkage,
  creates a brand-new account** — and does so with `Role: RoleUser`, not
  admin, even though the very first-ever local account is auto-admin.
  If registration is closed by the time this happens, it fails outright
  ("user registration is not allowed") rather than falling back to
  linking anything.
- **The correct way to attach SSO to an already-existing account** is a
  *different* RPC, `CreateLinkedIdentity` (`UserService`), which requires
  being authenticated *as* that account already and calls
  `bindSSOIdentityToUser` rather than the miss-path account-creation
  logic. In the web UI this is Settings → My Account → the linked
  identity providers section (`LinkedIdentitySection.tsx` — confirmed via
  GitHub code search, since it isn't reachable from the plain sign-in
  page's OAuth button, which always takes the "signin" flow, never
  "link").

So the actual bring-up order that avoids ending up with a stray
non-admin duplicate account:
1. Complete Memos' first-run password signup as normal — this is the
   real admin account.
2. Create the Infomaniak IdP entry (`idp create`, endpoints below).
3. **While still logged in with that password account**, go to
   Settings → My Account and link the Infomaniak identity from there —
   not by signing out and using "Sign in with Infomaniak" on the login
   screen.
4. Verify the linkage server-side (`user linked-identity-list
   users/<username>` — should show the IdP with the expected
   `externUid`) before locking anything down.
5. Only then set `disallowUserRegistration: true` and
   `disallowPasswordAuth: true`.

**Infomaniak endpoints** (from
`https://login.infomaniak.com/.well-known/openid-configuration` — don't
guess these, confirmed live):
```
authUrl:     https://login.infomaniak.com/authorize
tokenUrl:    https://login.infomaniak.com/token
userInfoUrl: https://login.infomaniak.com/oauth2/userinfo
scopes:      openid, email
```
Redirect URI registered on Infomaniak's IK-AUTH side must be exactly
`https://marque.mathewcsims.uk/auth/callback`.

**Credential handling:** the Infomaniak client secret was never typed
into a Bash command directly (caught by the session's own credential-
leakage safeguard on the first attempt) — it's fetched from the "Marque"
Pass item's `MARQUE_OIDC_CLIENT_ID`/`MARQUE_OIDC_CLIENT_SECRET` fields
into a shell variable, and the `idp create` config JSON is built in a
short Python snippet that reads from `os.environ` rather than ever
having the value appear as a literal argv string.

### Rate-limit bug found and fixed here — affects Owl and Prospect too

While live-verifying Marque's Caddy rate-limit zone (`rl_marque_auth`),
25 rapid `POST` requests all reached the backend with zero `429`s. The
zone's `match path /api/v1/auth/signin /api/v1/auth/refresh` was
matching the grpc-gateway REST surface — but the actual web app talks to
Memos over **Connect-RPC**, at `/memos.api.v1.AuthService/SignIn` and
`/memos.api.v1.AuthService/RefreshToken` instead (confirmed both via a
live network-request capture during setup and by reading
`proto/api/v1/auth_service.proto` for the exact service/method names).
The REST path was never what real traffic — or a real attacker — uses,
so this rate limit had silently never been enforced.

**This same zone shape was copied onto Owl and `prospect-ukri-tus`
verbatim**, so both had the identical gap. Fixed all three site blocks in
`pi-reverse-proxy/Caddyfile` to match both path forms (REST and
Connect-RPC) for the signin/refresh zones, and Prospect's registration
zone too (`/api/v1/users` → also `/memos.api.v1.UserService/CreateUser`).
Verified live on all three after redeploying: exactly 20 (or 5, for
Prospect's registration zone) requests succeed before `429`s start.

---

## Nimbus (https://dashboard.mathewcsims.uk) — DECOMMISSIONED (ran on the Pi, not the Mac)

> **DECOMMISSIONED 2026-08-04.** Torn down for lack of use. Containers,
> images, volumes, networks, the Caddy site block, the Uptime Kuma monitor
> and the DNS records are all gone; `nimbus/` was removed from this repo and
> survives only in git history. The section below is kept verbatim as the
> rebuild recipe. A final database dump and a cold `tar.gz` of the whole
> data directory live in `db-dumps/decommissioned/` on the Pi, and the
> **Nimbus** Proton Pass item was deliberately retained — between them,
> everything needed to stand this back up still exists.


[Nimbus](https://github.com/Turbootzz/Nimbus) monitoring dashboard — the one
deliberate exception to "everything runs on the Mac": it's on the **Pi**
instead, so the dashboard itself stays up if the Mac goes down for
maintenance. It monitors services via **HTTP polling** (checks URLs you add in
its own UI after setup) — no Docker socket access, nothing privileged.

**Two containers, same pattern as FreeScout's app+db split:**
- `nimbus` — the app (`turboot/nimbus` image)
- `nimbus-db` — Postgres (`turboot/nimbus-postgres`), never published anywhere,
  reached only by `nimbus` over the project's own default network

**Networking is different from every other app here, because Caddy and Nimbus
are BOTH on the Pi** (every other app's Caddy-to-backend hop crosses from the
Pi to the Mac, so it needs the Mac's real LAN IP). Caddy runs in its own
container — `127.0.0.1` from inside Caddy's container would hit itself, not
the Pi host, so a host-loopback bind wouldn't actually be reachable from
Caddy, and a LAN-IP bind (the Mac-app pattern) would work but needlessly
expose port 3000 to the whole LAN when nothing but Caddy ever needs it. So
instead: `pi-reverse-proxy/compose.yaml` creates a Docker network called
`pi-shared`; `nimbus/compose.yaml` joins it as `external: true`; Caddy
proxies to `nimbus:3000` by **container name**, and Nimbus's compose file
publishes **no host port at all**. Deployment order matters because of this —
`pi-reverse-proxy` must be up first to create `pi-shared` before `nimbus` can
join it (it already is, so this only matters if you ever tear both down).

**To bring it up:**
1. **Pi — redeploy `pi-reverse-proxy` first** (it now also creates the
   `pi-shared` network and the Caddyfile has a new site block):
   ```sh
   # copy the updated pi-reverse-proxy/ folder over, then on the Pi:
   cd ~/pi-reverse-proxy
   docker compose up -d        # up -d, not restart — network/compose changed
   ```
2. **Pi — deploy Nimbus** (a separate folder, separate compose project):
   ```sh
   # from the Mac:
   scp -r self-hosted/nimbus mathewcsims@10.0.1.19:~/
   # on the Pi:
   cd ~/nimbus
   docker compose up -d
   docker compose logs -f nimbus   # watch first-boot migrations
   ```
3. **DNS** (registrar): add `A` record `dashboard` → your WAN IP.
4. **NextDNS rewrite**: add `dashboard.mathewcsims.uk` → `10.0.1.19`.
5. Watch `docker compose logs -f caddy` (in `pi-reverse-proxy/`) for the cert,
   then visit `https://dashboard.mathewcsims.uk`.

**Login:** `mat@mathewcsims.uk` / a generated password — see
`INITIAL_ADMIN_PASSWORD` in `nimbus/.env` (gitignored — see `.env.example`
for the template). **Change it after first login.** This account is only
auto-created on a genuinely empty database.

**Adding your services to monitor:** done in Nimbus's own UI after logging in
— add each URL you want tracked (e.g. `https://cp.mathewcsims.uk`,
`https://prospect-ukri-tus.mathewcsims.uk`, the LAN URLs of anything not
internet-facing). Nothing for me to pre-configure here; it's polling-based, so
there's no agent or credential to install on the monitored apps themselves.

**Two known upstream bugs, both worked around in our Caddyfile — needed for
avatar/service-icon uploads to actually display:**

1. Avatar uploads write to `/uploads/avatars/<file>` and that exact path (no
   `/api/v1` prefix) is what Nimbus stores as `avatar_url` and returns to the
   frontend. But Nimbus's own bundled nginx only routes `/api/*` to the Go
   backend that actually owns that path — everything else falls through to
   the Next.js frontend, which 404s. The upload itself always succeeded (file
   on disk, DB updated); only *displaying* it afterward was broken. Fixed
   with a `rewrite` that rewrites `/uploads/*` → `/api/v1/uploads/*` before
   proxying.
2. Deeper bug, same symptom: Next.js's built-in image optimizer
   (`/_next/image?url=...`) does its own **internal** fetch of the source
   image from Next's own process, never through the nginx layer that bridges
   to the Go backend — so even a correctly-prefixed `/api/v1/uploads/...` URL
   gets Next's own 404 HTML page internally, which its image library then
   rejects as "not a valid image." Confirmed directly: `docker exec nimbus
   wget http://127.0.0.1:3001/api/v1/uploads/avatars/<file>` returns Next's
   own 404 page. This can't be fixed by proxying differently — the failing
   request never leaves the container — so instead Caddy intercepts the
   outer `/_next/image` request before Next's optimizer gets it and rewrites
   straight to the raw (already-working) image path, **scoped narrowly** to
   `/api/v1/uploads/*` targets only (not every `/_next/image` request), so it
   can't be abused as an open internal-path redirector.

   Getting the matcher right took real trial and error, kept here so it's not
   relearned: Caddy's plain `query` matcher **only supports exact-value or
   bare `*` (any-value) matches — no substring/prefix globbing**, confirmed
   from Caddy's own `matchers.go` source (`slices.Contains(paramVal, v) || v
   == "*"`). A CEL `expression` matcher is needed for the `.startsWith()`
   check instead. And within an `expression`, a Caddy placeholder like
   `{http.request.uri.query.url}` **must stay unquoted** — it gets expanded
   into a proper CEL function call (`ph(req, "...")`) before compilation, not
   substituted as literal text; wrapping it in quotes turns it into an inert
   string literal that can never match anything.

Both fixes survive Nimbus image updates since they live in our Caddyfile, not
inside their container.

**Outgoing email (password resets)** — configured via the admin UI
(Settings), not `compose.yaml` — SMTP via ProtonMail is already set up.

**OAuth (Infomaniak, via generic OIDC)** — `OIDC_ISSUER_URL` and
`OIDC_REDIRECT_URL` are fixed values in `nimbus/compose.yaml` (not secret);
`OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET` (from an app created under IK-AUTH)
live in `nimbus/.env` (gitignored — see `.env.example`):
```
OIDC_ISSUER_URL:    https://login.infomaniak.com        (compose.yaml)
OIDC_CLIENT_ID:     <from an app created under IK-AUTH>  (.env)
OIDC_CLIENT_SECRET: <from an app created under IK-AUTH>  (.env)
OIDC_REDIRECT_URL:  https://dashboard.mathewcsims.uk/api/v1/auth/oauth/oidc/callback (compose.yaml)
```
Nimbus auto-discovers the authorize/token/userinfo endpoints from
`OIDC_ISSUER_URL` at startup — confirm it worked with
`docker compose logs nimbus | grep OIDC` (expect `OIDC provider enabled`).

Two things worth knowing if you ever touch this again:
- **IK-AUTH** (`manager.infomaniak.com/.../products/cloud/ik-auth`) is where
  you register the OAuth application (flat "create application" step, no
  separate realm/tenant) — but it issues clients against Infomaniak's
  **shared** identity service at `login.infomaniak.com`, the same one their
  generic "Log in with Infomaniak" consumer button uses. It is *not* a
  separate per-account Keycloak-style instance with its own issuer, despite
  living under a project-scoped manager URL — confirmed by fetching
  `https://login.infomaniak.com/.well-known/openid-configuration` and getting
  back exactly the authorize/token/userinfo endpoints IK-AUTH itself reported.
- **New-account creation via OIDC is gated by `public_registration_enabled`**
  (a Nimbus admin setting, currently `false`) — but *linking* an OIDC login to
  an **existing** account by verified email is a separate, ungated code path.
  So this only ever logs in the account whose email matches the Infomaniak
  account used — it can't be used by an arbitrary Infomaniak user to
  self-register, without needing to touch that setting at all.

Redirect URI must match **exactly** between the IK-AUTH application and
`OIDC_REDIRECT_URL` — Infomaniak will reject the exchange with a
`redirect_uri` mismatch otherwise. Env changes need `docker compose up -d`
(not `restart`) to take effect.

**Not covered by the Mac's launchd auto-start.** Because Nimbus runs on the
Pi, `autostart/` (which only starts the podman machine on the Mac) doesn't
apply to it — Docker's own `restart: unless-stopped` plus Docker starting at
boot (Pi default) is what brings it back after a Pi reboot, same as Caddy.

---

## Task management: SEARCH CLOSED 2026-08-08 — nothing off the shelf fits

> **STATUS 2026-08-08: no tool in place, and the search for one is over.**
> Vikunja — the incumbent throughout everything below — was decommissioned on
> 8 August, holding 11 tasks in 2 projects. organice was deployed 7 August and
> torn down 8 August. The field has now been swept five times and is
> exhausted; the conclusion is that **the requirement set has no off-the-shelf
> answer**, for structural reasons rather than bad luck. See *The fifth sweep*
> below for what was checked in source and what the two structural results
> are.
>
> **SUPERSEDED 2026-08-08 (later the same day) — a three-tool answer was
> adopted and deployed.** Not a single product, and not the build below:
>
> | Tier | Tool | Where |
> |---|---|---|
> | Backlog — someday/now/done/never | **Fizzy** | `fizzy.mathewcsims.uk`, LAN-only |
> | Day-to-day detailed to-dos + reminders | **Super Productivity** | `sp.mathewcsims.uk`, LAN-only, syncs to copyparty |
> | Recurring chores | **Tasks.org** | phone **and watch**, local, no sync |
>
> **Why this works where five sweeps failed: each tool's fatal flaw is
> neutralised by the role it is given.** Tasks.org's door-closer was that
> `repeat_from` does not sync — irrelevant when it never leaves one device.
> Super Productivity's was having no server, so reminders are per-device
> with no backstop — acceptable for work you are actively engaged with, once
> the must-not-miss chores live elsewhere. Fizzy's flatness does not matter
> because a backlog is a list. The `card_not_nows` table means "not now" is
> a first-class concept in Fizzy, not a column convention.
>
> Tasks.org earned its place on something no other candidate had: real
> `:wear` and `:wear-datalayer` Gradle modules — a genuine watch app with a
> data layer, not mirrored notifications.
>
> **What this does NOT cover: deep decomposition.** Fizzy's `steps` are a
> flat checklist (no nesting, no ordering, no promote-to-card) and Super
> Productivity is one level in practice. The original "closer to a genuine
> project planning system" requirement is unmet, knowingly.
>
> The build below is shelved, not cancelled. Everything above it stands as
> the record of why nothing off-the-shelf fits as a single product.

### The requirements, restated 2026-08-08

Three high-level needs, and **a combination of tools is acceptable as long as
the seams actually hold**:

1. **Backlog**, hand-orderable and prioritisable.
2. **Repeating tasks** — bins, weekly timesheet, end-of-week wrap-up — with
   labels, sub-tasks, a reminder at the time the thing needs doing, and
   completion each cycle.
3. **Complex decomposition**, closer to a genuine project planning system.

Moving items from 1 into 3 programmatically is a nice-to-have, not a
requirement — and it disappears entirely if 1 and 3 are the same tool, since
promotion is then just re-parenting.

Two clarifications that changed the search materially:

- **"Disruptive" replaced "nagging".** The requirement is *notifications
  sufficiently disruptive that they are not easily ignored* — not
  specifically MedTimer's repeat-until-actioned mechanism. That is a property
  of the notification channel, not the task app, which is why it only has to
  work on the phone.
- **Both recurrence anchors, evenly.** Calendar-anchored *and* from-completion,
  in roughly equal measure. Not one or the other.

And one requirement that turned out to be the sharpest filter of all:
**sub-tasks on a repeating task must reset each occurrence.** That means the
occurrence has to be a *clone*, not a date-bump on the same row — which also
determines whether per-occurrence history can exist at all.

### The fifth sweep (2026-08-08) — checked in source, not from docs

| Tool | Verdict | Evidence |
|---|---|---|
| **Donetick** | Meets requirement 2 almost completely | `IsRolling` bool is per-chore and orthogonal to frequency type, giving both anchors per task; `ResetSubtasksCompletion()`; per-chore IANA timezone; completion fires notifications synchronously. Flat sub-tasks, so not a decomposition tool. **`snooze` appears nowhere in the codebase.** Ruled out by Mat |
| **TaskTrove** | Best recurrence model found anywhere — and still fails | `recurringMode` is a per-task union of `dueDate` / `completedAt` / `autoRollover`. But `SubtaskSchema` is flat (no parent ref on tasks), and `notification-scheduler.ts` schedules a **browser `setTimeout`** — no server-side scheduler, no webhook, nothing to bridge to ntfy. **Dormant**: last commit 2026-01-09. Sustainable Use License (source-available, not OSI) |
| **Huly** | Real arbitrary nesting — `attachedTo: Ref<Issue>` plus a materialised `parents: IssueParentInfo[]` | Rejected: bundles chat, video, HR and CRM across 10+ services. The Plane objection |
| **Wekan** | Real arbitrary nesting — `parentId` with an unbounded ancestor walk (`models/cards.js`) | Rejected on interface. Also a Meteor + MongoDB stack, ~9 images |
| **Planka** | Out on structure | `List → Card → TaskList → Task`, fixed depth, no self-parent. Recurrence is pro-only |
| **Kaneo** | Out on structure | No task parent ref; nested subtasks is open FR #1170 |
| **Kanboard** | Out on structure | Recurrence duplicates the task (so sub-tasks and history do work) but is **event-triggered only** — no calendar anchoring. Sub-tasks flat |
| **Forgejo** | Not yet possible | Sub-issues are an unmerged WIP PR (#6267) |
| **OpenProject** | No native recurrence | #29120 open 5+ years; community works around it with an external cron daemon. Also the weight objection |
| **Leantime** | Recurrence is a **paid marketplace plugin** for self-hosted | — |
| **TaskView** | Feature-complete on paper | Source-available with a paid tier — licence mismatch for this repo |
| **TriliumNext** | Native arbitrary tree, but tasks are a **trial plugin** | The HamsterBase objection |
| **Focalboard** | Dead | Archived by Mattermost 2023, last release Jun 2024 |
| **Todoist** | Genuinely meets the spec | Ruled out: not private, and no E2EE |

### The two structural results

These are the useful output of the whole exercise, and they explain why five
sweeps failed:

**1. Arbitrary nesting and light weight are anti-correlated.** Everything in
this category that decomposes properly is a platform (Huly, Plane,
OpenProject) or a fat stack (Wekan); everything light is flat (Planka, Kaneo,
Kanboard, TaskTrove). The only tools at the intersection were Vikunja
(rejected on interface, and now adding a Pro tier), Focalboard (dead) and
TaskView (source-available).

**2. Privacy and reliable nagging are in direct tension.** Todoist can pester
you dependably *because* its servers read your tasks and push. E2EE tools
cannot do that by construction — if the server can't read the data it can't
decide when to ping — so reminders fall back to the client, which is exactly
TaskTrove's failure mode. The self-hosted middle ground mostly doesn't
schedule server-side at all, or only knows how to send email.

**The missing component is therefore narrow and specific: a server-side
scheduler that pushes.** Not a task manager — something that knows a time, a
topic and a title. It does not need to read the tasks, which is what makes it
compatible with the privacy requirement. `ntfy/` and `apprise/` are already
deployed, so delivery is solved; scheduling is the gap.

**Interface is the real binding constraint**, not features: Vikunja, Super
Productivity, Kanboard, Wekan and HamsterBase all died on it, and Plane and
Huly on bloat. Hence the agreed sequencing — build the interface first,
against fixed sample data, before any backend exists. That is the design
phase of a waterfall project, not iterative delivery of half a product.

**The superseded decision of 7 August 2026.** Everything below this block is kept as
history and as a list of candidates not to re-propose. **Three of its stated
requirements are wrong** — see *Where the old framing went wrong* and *Kanban
was excluded on a false premise* — and between them they are why fifteen
candidates failed across four sweeps:

> 1. that Problem A is a full task manager rather than a reminder engine;
> 2. that a server firing the reminders is non-negotiable;
> 3. that Kanban layouts should be excluded.

### Problem A — recurring chores with nagging reminders

- **Tasks.org** ([tasks/tasks](https://github.com/tasks/tasks), GPL). The
  **F-Droid Android build** does the nagging; the **desktop build**
  (macOS/Windows/Linux, shipped in GitHub releases) views and edits.
- **Radicale**, holding **one task collection**, as the sync backend.
- **Thunderbird's Tasks view comes free** — it already runs as the mail and
  calendar hub and reads `VTODO` over CalDAV, so the server feeds two surfaces
  that already exist.

The reference model for the reminder behaviour is **MedTimer**, the Android
medication app already in daily use: repeating notification until explicitly
actioned, with actions on the notification itself. Tasks.org matches it —
`ring_nonstop` / `ring_five_times` ring modes per alarm, Complete and Snooze
actions, `SCHEDULE_EXACT_ALARM` plus a boot receiver, and RRULE recurrence so
"Wednesdays and Sundays" is **one task**.

### Problem B — deep project and life management

- **organice** over **copyparty's existing WebDAV** — no new server — plus a
  small **read-only** script parsing `SCHEDULED:`/`DEADLINE:` and pushing to
  Apprise.

A web UI is cross-platform by construction, which is what makes this work
without per-platform builds or a sync protocol.

### Open before deploying

1. **Whether the Tasks.org interface is bearable.** This is the only untested
   thing that can still kill A, and interface has killed four candidates
   (Vikunja, Super Productivity, Plane, HamsterBase). Install from F-Droid and
   look before building anything.
2. **Whether WebDAV is enabled in `copyparty/cfg/copyparty.conf`.** Both halves
   of B depend on it.

### Facts established 7 August, worth not re-deriving

- **Tasks.org nagging is Android-only.** `composeApp/src/desktopMain` contains
  no reminder or alarm implementation at all; desktop is a viewer and editor.
- **The paywall differs by build.** Android F-Droid is fully unlocked
  (`Inventory.kt` — `hasPro` returns true when `IS_GENERIC`). The **desktop
  build is entitlement-gated**: `DesktopEntitlement` defaults `_hasPro` to false
  and verifies a signed `entitlement.json`, alongside `GitHubSponsorClientImpl`.
- **Tasks.org cross-platform sync is CalDAV-only.** DecSync and DAVx⁵ are
  Android *companion-app* integrations with nothing in `jvmCommonMain`; CalDAV
  has a full implementation there. This is why a server is unavoidable.
- **Radicale is not a groupware bundle.** `radicale/app/` is organised by HTTP
  verb (`get.py`, `put.py`, `propfind.py`, `report.py`…), not by feature, and a
  collection's type is a property set at creation (`tag == "VADDRESSBOOK"`) — so
  an addressbook exists only if you create one. 89 Python files, 2.3 MB of
  source, five dependencies, one process, plain files on disk. The objection it
  answers — "a CalDAV server runs calendar and contacts services I don't need" —
  describes Nextcloud, not Radicale.
- **organice never merges.** It does optimistic concurrency with a Pull/Push
  modal (`src/actions/org.js:157-206`) and force-pushes without the modal while
  a sync is already in flight. A third writer clobbers edits, which is why the
  reminder script must stay **read-only**, with its state in a sidecar file.
- **Org-mode cannot express weekday sets.** `OrgRepeater.Type` is only
  `+` / `++` / `.+` with an interval unit, and there are **zero** references to
  weekday, day-of-week or BYDAY anywhere in org-java. "Wednesday and Sunday"
  needs two headlines. This is why A is not org-mode, despite B being org-mode.

### Where the old framing went wrong

Three requirements recorded below are **wrong**, and between them they
eliminated most of the field:

1. *"Problem A is still a task manager… any claim that it reduces to a scheduler
   and a list is an inference, and it is wrong"* — A **is** just that: recurring
   reminders with a way to tick them off. No projects, labels or nesting.
2. *"That server requirement is the whole reliability argument"* — **disowned.**
   MedTimer is purely on-device and is trusted for medication, which is
   higher-stakes than bins. Client-scheduled alarms are acceptable. This premise
   alone eliminated Super Productivity, Mindwtr and HamsterBase.
3. *"List-first, not Kanban"* — **wrong; Kanban is liked.** This removed an
   entire category from four sweeps. Re-swept 2026-08-08 and it cost little in
   practice, because self-hosted Kanban tools almost never implement
   recurrence — but the exclusion should never have been applied. See *Kanban
   was excluded on a false premise* above.

A fourth, methodological error compounded them: *"Depth is the primary filter —
test it first"* was correct for the combined requirement, but A needs no depth,
so screening on depth first meant A-suitable candidates were binned before
anything relevant to A was assessed.

### Also rejected on 7 August — do not re-propose

**HamsterBase Tasks** (a notetaking app with a half-baked tasks concept bolted
on — though its `ParentRules` does permit arbitrary task nesting, which
falsifies the "nothing nests past two levels" claim below); **Plane** (too
heavyweight; Community Edition is also only at Cloud Free-tier parity);
**Healthchecks** (a cron monitor repurposed as a reminder engine — the per-check
alert fires **once** on going down, and the `nag` feature is an account-wide
email-only digest, not per-item re-notification); **Super Productivity**
(interface "unbearably twee" — note every *technical* objection had collapsed:
weekday booleans still present, the WebDAV rewrite landed at `src/app/op-log/`,
and it nags via `CATEGORY_ALARM` plus `setOngoing`); **Tududi** (already binned,
and redundant in the role it was proposed for).

Verified dead, both with misleading recent `pushed_at` from bot activity:
**MIND** (last real commit 23 Nov 2024) and **remembear** (6 Dec 2022).
**Mindwtr**'s security advisory is patched in 1.1.5, but it has **no task
nesting at all** — only its importers reference `parentId`, and the OmniFocus
importer flattens hierarchy into a text prefix.

Two corrections to the history below: **Tududi** has since gained a server-side
`node-cron` scheduler, weekday-set recurrence (`recurrence_weekdays`), and a
full CalDAV server *and* client — though its scheduler fires on `due_date`, not
`reminder_at`, so "no time-of-day reminders" still holds in substance. And
**Vikunja's RRULE PR** [#3071](https://github.com/go-vikunja/vikunja/pull/3071)
needs a breaking 3.0.0 release plus a second UI PR; the maintainer estimated
September, "probably not until October" — so it is not something to wait for.

---

## History: three replacements attempted, none adopted (2026-07 → 2026-08)

Kept for the candidate assessments and the traps, which remain accurate. The
requirement list immediately below is **superseded** — see above.

Vikunja was the task manager throughout. Three attempts were made to replace it —
Donetick in July, Tududi and Donetick again on 1 August — and all three were
removed. The requirement set is harder to satisfy than it looks, and the same
candidates keep resurfacing.

### The requirements, as they were finally articulated

1. Recurring "chore" tasks **and** genuinely one-off tasks, both handled well
2. ~~List-first, not Kanban~~ — **WRONG, corrected 2026-08-08. Mat likes
   Kanban.** This requirement excluded an entire category across four sweeps
   and should never have been applied. See *Kanban was excluded on a false
   premise* below before rejecting anything for its layout.
3. A clean, modern interface
4. Cross-platform — Windows, Android, macOS, iOS
5. Free with full functionality; **no paywall-gated features**
6. Longevity, and evidence of sustained maintenance
7. **Privacy** — which means end-to-end encryption *or* self-hosting. Note
   this is the actual driver; self-hosting is a means, not the goal
8. **Reminders at a specific time of day, set in the tool, repeating on
   every occurrence of a recurring task**
9. Delivery via ntfy/Apprise and/or email
10. Projects **and** labels — two independent axes — with **arbitrarily deep
    subtasks**: complex tasks broken down repeatedly until atomic. In practice
    that means **15–20 levels**, which is how the same task decomposes on
    paper. Not a checkbox; it is the working method
11. An API for automation

Requirement 4 means genuinely equal access on every device: a **web interface
for serious work** and a **mobile app for quick capture on the go**, with the
mobile side still reaching everything — not a cut-down view.

### Kanban was excluded on a false premise (corrected 2026-08-08)

Requirement 2 said "List-first, not Kanban". **That was wrong — Kanban is
liked, not disliked**, and the requirement removed an entire category from
four consecutive sweeps. It is the third premise in this section found to be
false, alongside "Problem A is still a task manager" and "the server
requirement is the whole reliability argument".

The category was re-swept on 2026-08-08 to see what the exclusion had cost.
**Almost nothing, as it turns out** — self-hosted Kanban tools overwhelmingly
do not implement recurrence at all:

| Tool | Recurrence | Verdict |
|---|---|---|
| **Planka** (12.3k⭐, active) | **Pro-only paywall** — `proFeatureRecurringCards: '✨ Recurring Cards & Automation'` in the locale files | out on requirement 5 |
| **Wekan** (21k⭐, active) | **None.** Its `RRULE` references are in the ICS *import* doc, which explicitly lists recurrence rules, alarms and timezones among what it does **not** convert. "Recurring cards" sits in `Roadmap.md` marked *"Not started yet"* against a Bountysource issue | out |
| **Kaneo** (7.6k⭐) | none | out |
| **4gaBoards** (685⭐) | none | out |
| **Fizzy** (8k⭐, 37signals) | none — no `recur`/`repeat`/`rrule` column in the schema | out |
| **Taskcafe** (5.2k⭐) | — | **dead**: `pushed_at` says Jul 2023, last real commit **Sept 2022** |
| **Kanboard** (9.8k⭐) | ✅ **including from-completion** — `RECURRING_TRIGGER_CLOSE` + `RECURRING_BASEDATE_TRIGGERDATE` | interface rejected on sight |
| **Vikunja** | ✅ including from-completion, **and it has a Kanban view** | interface (the standing objection) |

**The finding worth keeping:** the only two self-hosted Kanban tools that do
recurrence properly are the two already rejected on their interfaces, and both
are older and more feature-complete than the modern good-looking ones. Liking
Kanban does not open a new field — it re-presents the same two tools.

Note also the recurring `pushed_at` trap: Taskcafe looked alive by that field
and was four years dead. **Always check the actual commit log.**

### These are two separate problems, not one (established 2026-08-02)

The single most useful outcome of the whole exercise. **The requirement list
above is two different tools wearing one coat**, which is why nothing has ever
satisfied it — the search kept intersecting two feature sets no product
optimises for at once.

**Problem A — recurring chores and day-to-day tasks.** Walking, bins, phoning
Mum, Royal Mail renewals. This is **the full requirement list above minus deep
nesting, and nothing else**. Projects, labels, a real mobile app, sync between
devices, a modern interface and an API are all still required. What it adds
is an explicit **server**: something holding the truth that fires reminders
regardless of what any device is doing. That server requirement is the whole
reliability argument, not a nice-to-have — client-scheduled alarms have no
independent backstop, so if the phone does not fire, nothing does.

*Recorded because it was got wrong once:* "depth doesn't enter the picture"
means **only** that 15–20 level nesting is not needed here. It does **not**
mean flat, and it does not mean small. Problem A is still a task manager.
Any claim that it reduces to "a scheduler and a list" is an inference, not a
requirement, and it is wrong.

**Problem B — decomposed tree work.** Complex work broken down repeatedly;
the tasks are the *leaves*. Needs 15–20 levels, editing everywhere, a big
screen for the tree, privacy. Needs **no** recurrence and **no** reminders —
structure is the job, and only leaves are ever actionable.

The overlap is small. Split this way, Problem B has three good answers
(Logseq, SiYuan, Trilium — all AGPL, self-hostable, active, arbitrary depth
as their core premise). Problem A remains unsolved.

**Priority: A now, B someday.** B is the half with good options available,
but A is the half that has to be resolved.

**A constraint that exists before any tool is chosen:** a 15–20 level tree
cannot render on a phone. Mobile will always show a slice — the actionable
leaves — never the tree. Depth and mobile were never going to be served by
one view, so the split is forced by the devices, not by software
availability.

The open design question for Problem A is what happens when a leaf becomes
actionable: move it by hand (zero engineering, and arguably the point), or
bridge it automatically (real work — defer until the manual version proves
annoying).

### Depth is the primary filter — test it first (established 2026-08-02)

**Nothing in the field nests more than two levels.** That single requirement
eliminates every candidate below faster than any other, and it was not
recognised as the binding constraint until the sweep was re-run on 2 August.
Interface and reminders got the attention; depth was quietly doing the work.

| Depth supported | Candidates |
|---|---|
| None — no `parent_id` at all | Tracks; Notesnook, Joplin, AppFlowy (notes-shaped) |
| One level | **Tududi**; **Super Productivity** ([#2657](https://github.com/super-productivity/super-productivity/issues/2657) open since Jun 2023, *low priority*); Nextcloud Tasks' mobile client |
| Arbitrary | **Donetick** (out on the project filter); **CalDAV `VTODO`** via `RELATED-TO` (out on the interface) |

So exactly two things in existence meet the depth requirement, and both are
broken somewhere else.

**Check depth before anything else.** It takes seconds, it is rarely
advertised honestly, and it eliminates most of the field. Every other
requirement on the list — reminders, recurrence, projects, labels, web UI,
self-hosting — is comparatively common.

The reason is structural: task apps model a *list* with nesting bolted on,
because that is what most users want. A 15–20 level decomposition is a
*tree*, and the tool is not storing the structure so much as being the
thinking. Two levels does not partially serve that — it breaks at exactly the
point the method starts paying off. This is also why paper keeps pulling: it
does arbitrary depth effortlessly, and fails instead on portability,
editing and reminders.

### What each candidate failed on

| Candidate | Fails on |
|---|---|
| **Vikunja** (incumbent) | Interface (3) — and that is the *only* live objection. Recurrence (1) was the other: three repeat modes exist (interval in seconds, monthly, from-completion), so "Wednesdays and Sundays" is inexpressible and needs two tasks — but [PR #3071](https://github.com/go-vikunja/vikunja/pull/3071) (open 1 Jul 2026) replaces the whole model with RFC 5545 RRULE across API, migrations, CalDAV and frontend, making `FREQ=WEEKLY;BYDAY=WE,SU` expressible. Maintainer engaged ("This is big, I probably won't get to review it immediately"), automated review panel approved with nits, currently needs a rebase. Depth and reminders both already fine |
| **Tududi** | **No time-of-day reminders at all** (8) — `reminder_at` is a database column nothing writes to; the API accepts the field and silently discards it. Subtasks capped at **one level** (10) |
| **Donetick** | **Basic usability (3)** — the home view shows only tasks with *no* project, and "all projects" has no representable value, so the selection cannot survive a refresh. Put your tasks in projects and the default view is permanently empty. The maintenance backlog (86 open issues, oldest Feb 2025; 26 open PRs, oldest Sep 2025) is not the failure itself — it is why the defect is **unfixable in practice**, since a patch would be a permanent fork |
| **Plane / Huly** | Hardware — 4–8 GB and 8–16 GB RAM respectively; slartibartfast has ~4 GB free after Immich |
| **Nextcloud Tasks** | Requires running Nextcloud to get a task list |
| **CalDAV + native clients** | No browser interface |
| **Anytype / EteSync** | Bloat, and a sub-par web interface |
| **Apple Reminders** | No Android; **Advanced Data Protection is unavailable in the UK** since Feb 2025, so not E2E here either |
| **Todoist / TickTick** | Not end-to-end encrypted (7); Todoist paywalls reminders (5) |
| **TaskTrove** | Licence is "Sustainable Use" — source-available, not open source; and stale since Jan 2026 |
| **HamsterBase Tasks** | Recurrence — `calculateRecurringDate.ts` is interval-only (years/months/weeks/days); "1w" means *next Monday*. Weekday sets are inexpressible |
| **Tracks** | Hierarchy and reminders — supports weekday sets, but no `parent_id` on any model and no notification code at all |
| **Notesnook** | Reminders — recurrence supports weekday sets on paper, but the reminders do not work in practice (tested directly). Also notes-shaped: reminders attach to a note, not to an item within it |
| **Joplin / AppFlowy** | Repeating to-do notifications are an open feature request; AppFlowy's reminders are in-app only, push still on the roadmap |
| **Super Productivity** | **No server (11)**, and depth (10). See the assessment below — it was the leading answer to Problem A until the sync model was read properly |
| **Lunatask** | No web interface (4) — desktop and mobile binaries only. Recurrence is paywalled at $6/mo or $300 lifetime (5). Tried directly: too complex and clunky |
| **SilentSuite** | Longevity (6) — repo created 19 Mar 2026, v0.4.2-beta, 660 of ~670 commits from one person, no native iOS client, GitHub does not detect the claimed AGPL licence. Also does calendar and contacts, which is unwanted scope. E2E via Etebase, self-hostable, real web app — the shape is right, the maturity is not |
| **Fizzy** (37signals) | ~~Kanban-first (2)~~ — not a valid reason, see requirement 2. Still out: **no recurrence code in the repo at all** (re-checked 2026-08-08 against `basecamp/fizzy` — no `recur`/`repeat`/`rrule` column in the schema; the "recurring" hits are Solid Queue job infrastructure), and its notifications are activity-based (comment, assignment), not due-date reminders (1, 8) |

Assessed and rejected without trial on 2 August: Super Productivity (depth),
Lunatask (tried directly — no web UI, clunky), SilentSuite (five months old,
one contributor, unwanted scope), Fizzy (no recurrence — the "Kanban" half of
that rejection was invalid, see requirement 2). Nextcloud
Tasks shipped web-UI recurrence in v0.18.0 (22 Jun 2026), which removes its
old technical objection — but Nextcloud itself remains **categorically ruled
out** as a dependency, so this does not reopen it.

### Super Productivity, assessed in the source (2026-08-02)

Worth recording in full because it got closest to Problem A, and because
**the parts that were verified all held** — the failure was somewhere nobody
was looking.

**Recurrence: genuinely good.** `task-repeat-cfg.model.ts` carries individual
weekday booleans (`monday?`…`sunday?`) alongside `repeatCycle: 'WEEKLY'` and
a `CUSTOM` quick setting, so "Wednesdays and Sundays" is **one task**. Also
monthly Nth-weekday anchors ("first Thursday", "last Monday") and
last-day-of-month.

**Reminders: genuinely good.** The repeat config carries `startTime` and
`remindAt` per configuration, so every generated occurrence gets its own due
time *and* its own reminder offset — the behaviour that stops reminders
drifting away from the recurrence. Delivery is real OS-level scheduling, not
an in-app badge: native `AlarmManager` on Android, Capacitor
`LocalNotifications` on iOS, service-worker/Electron notifications on
desktop, with done and snooze actions handled from the notification itself.
The manifest requests **`SCHEDULE_EXACT_ALARM`** and **`RECEIVE_BOOT_COMPLETED`**
with a `BootReceiver` that reschedules after reboot — the two things that
separate alarms which fire from alarms which mostly fire. It does *not*
request battery-optimisation exemption, so Samsung's "Sleeping apps" would
need setting manually.

**Why it failed: there is no server.** Sync writes the entire dataset as a
file blob to Dropbox / Nextcloud / WebDAV / a local folder; each device holds
everything and reconciles against a file. Consequences:

- **No API (11)** — a plugin system instead of a server API.
- **No independent backstop.** Reminders are scheduled per-device. If the
  phone doesn't fire, nothing else does. A server-side job parsing the sync
  blob was considered and rejected: the format is internal, undocumented, and
  **actively being rewritten** (operation log, vector clocks, SQLite
  migration, sync-engine extraction all in flight) — a reliability backstop
  on a moving format fails silently at the worst moment.
- **The WebDAV provider is labelled experimental** by upstream, and with
  Nextcloud categorically ruled out that is the only path available.
- SuperSync — operation-based, real-time, self-hostable, optional
  server-side E2E — would supply the missing server, but is **beta**.

**Lesson: check for a server before checking features.** Two hours went into
verifying recurrence and reminder code that was never the problem. For
Problem A the ordering is: server and API first, then depth, then reminders.

### Contribution health, measured rather than assumed (2026-08-02)

Two corrections to what this document previously implied:

- **Donetick does merge outside contributions**, and reasonably promptly —
  ~13 outside PRs merged Mar–Jul 2026, many within a week. The problem is
  variance, not refusal: 13 PRs have sat over 90 days, oldest Sep 2025. A
  fix you depend on daily cannot ride on a coin flip.
- **Tududi's tidy tracker was read as a good sign; it is a solo-maintainer
  artefact.** 49 of every 50 merged PRs are the maintainer's own. Small
  outside PRs land in 1–6 days, but [PR #762](https://github.com/chrisvel/tududi/pull/762)
  (push notifications, 2,294 lines) has had **zero maintainer response since
  6 Jan 2026**. Note also that #762 is notification *transport*, not the
  missing scheduler — it was never the head start it looked like.

The generalisable pattern: **small PRs and large feature PRs are different
products.** Vikunja merges stranger bugfixes same-day (TowyTowy, 13rac1,
taiwithers, maximilize all landed in Jul 2026) while ~24 feature PRs queue —
the oldest being the maintainer's *own*, open since Sep 2025. Judge a project
by the queue for the size of change you actually need, not by its headline
activity. AppFlowy is the failure case: 63 open outside PRs, oldest Oct 2023,
one merge in 120 days.

### Why Donetick was tried twice, and dropped twice

**July (096132c → f0bfc1d, 34 minutes apart):** removed because avatar
uploads needed S3, MinIO proved unmaintained, and Garage needed config that
couldn't be verified against the pinned release. Nothing to do with task
management. Upstream later added `storage_type: local`, which is why it was
reconsidered.

**August:** functionally it was the best fit assessed — `days_of_the_week`
recurrence, per-occurrence reminder templates computed from each occurrence's
due datetime, arbitrarily nested subtasks, projects, native mobile apps,
AGPL. It was deployed, migrated to, and wired through to Apprise.

**It failed on basic usability.** With tasks in projects, the default view
shows nothing at all — the project selector has no representable "all"
state, so the choice cannot survive a page reload. That is a daily,
present-tense failure, not a theoretical one.

The maintenance backlog is why that defect is **unfixable in practice**
rather than why the app was rejected: with 26 PRs unreviewed for up to ten
months, a fix would never land upstream, so patching means owning a
permanent fork rebased on every release.

Two process errors, recorded because both are repeatable. The backlog was in
the very first API response used to evaluate the tool and was not weighed —
while the same signal had been used two days earlier to *praise* Tududi's
tidy tracker. And the change needed to fix the defect was proposed before it
had been traced, with the uncertainty attached as a caveat rather than
treated as a blocker.

### Traps found along the way, worth keeping

- **Donetick's `DT_SQLITE_PATH`** is read with a plain `os.Getenv` and
  defaults to a *relative* path, so the database lands inside the container
  and is destroyed on `down` — while the app reports itself healthy and the
  bind mount sits empty.
- **Donetick's signup endpoint is `POST /api/v1/auth/`**, not
  `/api/v1/auth/signup`. It serves its own SPA, so any unmatched path returns
  `index.html` with **HTTP 200** — a probe against the wrong path looks
  exactly like a wide-open signup form. *Assert on the body, not the status
  code, when probing an app that serves a SPA.*
- **Editing an app's SQLite database directly bypasses its sync layer.**
  Remapping IDs by hand left every client showing zero tasks, because
  `sync_version` was never bumped. If a direct edit is unavoidable, follow it
  with an API write so the app updates its own versioning.
- **Vikunja's task update replaces rather than merges.** `POST /tasks/:id`
  with a partial body silently blanks every field you omitted — description,
  due date and priority were all lost this way and had to be recovered from
  the nightly dump. Always send the full object.
- **Deleting a Donetick project cascades to its tasks**, silently clearing
  `projectId`, including on completed tasks not visible in any current view.

### The exhaustive sweep, and the structural result (2026-08-02)

A deliberately complete search was run across eight independent channels, to
settle whether anything had been missed rather than to find one more
candidate:

1. **awesome-selfhosted's canonical Task Management section** — all 42
   entries enumerated. Everything not already assessed was Kanban
   (4ga Boards, Kan, Kanboard, Nullboard, Wekan, Tasks.md) — **dismissed on
   layout alone, which was a false premise; several were re-checked on
   2026-08-08, see below** — ticketing
   (Bugzilla, Zammad, FreeScout, MantisBT, OTOBO, Request Tracker, Roundup),
   time-tracking (Kimai, solidtime, TimeTagger, Traggo, Wakapi, Ziit,
   ActivityWatch), or single-purpose (Our Shopping List, Listaway,
   Focus Flow, Surmai).
2. **GitHub topic sweep** — ten query variants across `todo`, `todolist`,
   `task-management`, `gtd`, `reminders`, `selfhosted`, all creation dates,
   200+ stars, active since Feb 2026.
3. **New launches by creation date** — the search listicles cannot do, since
   they lag by a year or more. This is how Mindwtr and SilentSuite surfaced.
4. **E2E-encrypted commercial apps** — the other half of the privacy clause.
5. **PrivacyGuides community consensus.**
6. **CalDAV web clients and servers.**
7. **Dedicated reminder apps** (a different category from task managers).
8. **Household/chore-specific tools.**

Rejected in this sweep, with reasons: **Will Be Done** (AGPL, self-hosted,
weekday recurrence, but **zero** notification or reminder code in the repo —
only a backup scheduler; the "Kanban-per-project" objection was invalid); **chiri** (CalDAV client,
active, but desktop-only — no web app); **Zero-Friction Tasks** (E2E, web +
five platforms, but *deliberately* has no projects, paywalls recurring
reminders at €5.99/mo, no self-hosting, closed-source so the encryption
claim is unverifiable); **planify** (GNOME desktop only); **ChoreOps**
(a Home Assistant add-on); **Habitica** (self-hosting is documented for
development only); **CalDavZAP** (the only CalDAV web client, and a
decade-old interface); **jotty**, **taskview-community**, **remembear**,
**myTinyTodo**, **Task Keeper/piga**, **Taskwarrior**, **dootask**.

Independent corroboration, from a community that specialises in exactly this
question — the PrivacyGuides thread on E2EE tasks with sync concluded that
**no fully E2EE task app with reminders, recurrence and a web interface was
identified as available.**

**The structural result.** The field is not merely short of one feature. It
divides three ways, and every division is missing something different:

| Has | Lacks | Examples |
|---|---|---|
| Server + modern UI | **Privacy** | Todoist, TickTick |
| Privacy + modern UI | **A server** — reminders are client-scheduled, no independent backstop | Super Productivity, Mindwtr, Lunatask |
| Privacy + server | **A tolerable UI**, or has a broken feature in view | the incumbent; Donetick |

That is why fifteen candidates failed: not bad luck, but the three
requirements — privacy, a server that fires reminders, and an interface worth
using — are not held together by anything in existence in August 2026. The
commercial products finished the hard 20% because someone was paid to, which
is also why they are the ones without encryption.

**Do not re-run this search.** It is complete as of 2026-08-02 across all
eight channels. Re-check only by watching for *new* projects, and screen them
in the order given below.

### Where things stood on 2 August (superseded 7 August)

**Superseded — see the RESOLVED block at the top of this section.** The
conclusion below ("the field is exhausted", "nothing satisfies all eleven
requirements") was reached against the requirement list that has since been
corrected, and against a combined A+B problem that has since been split. Kept
because the candidate assessments and traps are still accurate.

Vikunja holds everything, unchanged throughout. The two divergences created
during the Donetick trial were merged back on 1 August: the
"Adjust repeat prescriptions" task, and Royal Mail marked done.

**Vikunja is no longer an acceptable resting place** — the interface rules it
out, stated plainly on 2 August. It holds the data because nothing else does,
not because it is the choice.

The field is exhausted, and the sweep was re-run properly on 2 August against
closest-fit-plus-contribution-health rather than pass/fail. Nothing available
in 2026 satisfies all eleven requirements, and **depth is why** — see *Depth
is the primary filter* above. Two things nest arbitrarily; both fail
elsewhere.

**Treat the two problems separately from here.** That is the change of
approach, and it is the reason the list below is shorter than it was.

**Problem B — the tree — is effectively solved and untried.** Logseq, SiYuan
and Trilium are all AGPL, self-hostable, actively maintained, and do
arbitrary depth as their core premise rather than as a feature request. The
thing that disqualified them as task managers — no reminders — is irrelevant,
because reminding is not this half's job. **But it is not urgent**: the tree
has lived on paper for years and can continue to.

**Problem A is the one that needs resolving**, and the requirement that kills
everything is the **server**. Note that A still needs projects, labels,
mobile, sync and a modern UI — dropping deep nesting narrows the search, it
does not shrink the product. Options, all previously rejected and recorded so
they are not re-proposed as though new:

1. **Build a client** over something that already nests and already fires —
   CalDAV `VTODO`, or an existing API. Not a task manager from scratch: the
   scheduler, recurrence engine, sync and delivery stay upstream. Rejected on
   2 August as not a sensible use of effort.
2. **Fund the gap** — sponsor or bounty a missing feature in a maintained
   project rather than write or fork it. Untested.
3. **Run a large platform at ~1% utilisation** — Home Assistant has the best
   reminder delivery in self-hosting (actionable notifications, re-nagging
   until ticked, watch bridging), total privacy, a server by definition and
   an enormous bus factor. Rejected on 2 August: an oversized workaround, and
   its recurrence lives in automation config rather than in the item.

**Mindwtr** ([dongdongbh/Mindwtr](https://github.com/dongdongbh/Mindwtr)) —
recorded in detail because it will look extremely promising to anyone who
finds it, and because two of the three findings took real digging.

- **Recurrence is right.** `packages/core/src/task-recurrence-fields.ts`
  carries `rrule`, `byDay`, `weekStart`, `until`, `count` and a `strategy`
  field for fixed-vs-from-completion. Weekday sets are expressible; "phone
  Mum on Wednesdays and Sundays" is one task.
- **Everything else on the list is met**: PWA plus Windows/macOS/Linux/
  iOS/Android, self-hosted sync server in Docker or WebDAV, projects with
  areas and sections, nested contexts as tags, REST API, CLI, an MCP server,
  AGPL. 1,578 stars in eight months.
- **But its server does not fire reminders.** `apps/cloud/` is auth, storage,
  attachments, rate limiting and a calendar feed — no scheduler, no push, no
  dispatch (zero hits for `webpush`, `cron`, `scheduler` in the repo).
  Reminders are client-scheduled, exactly as in Super Productivity.
- **One genuinely useful idea to keep, even though the app is rejected:**
  `apps/cloud/src/server-calendar-feed.ts` exposes an **ICS feed**. Unlike
  Super Productivity's internal sync blob, ICS is a documented, stable,
  standard format — so an independent server-side backstop (subscribe, parse
  with any iCal library, fire ntfy) is genuinely feasible rather than
  brittle. **Look for a standards-based export hook when judging whether a
  client-scheduled app can be given a server-side backstop.**
- **Rejected on security.** [GHSA-8x25-76x5-jgmr](https://github.com/dongdongbh/Mindwtr/security/advisories),
  published 28 Jul 2026: **cloud token and WebDAV password stored in
  plaintext on mobile.** Rated medium generically; disqualifying here, since
  that credential protects the whole dataset and sits unencrypted on the
  device most likely to be lost. An eight-month-old single-contributor
  project shipping a credential-handling flaw is the maturity risk made
  concrete rather than inferred.

Assessed for Problem A specifically and rejected: **MIND** (looked ideal —
server-side, weekday recurrence, Apprise delivery, API — but the main branch
has had no commit since 23 Nov 2024; `pushed_at` reflected branch activity,
not development, and three open issues meant nobody was filing them, not that
nothing was wrong); **Habitica** (self-hosting is documented for development
only, not production); **remembear** (three stars, one contributor);
**Grocy** and **Beaver Habit Tracker** (unexamined; household-inventory and
habit-streak shaped respectively).

Do not try a fifteenth candidate against the combined criteria — the
combination is the mistake. Screen Problem A candidates in this order:
**server and API first, then reminders, then recurrence, then projects and
labels, then mobile.** Screen Problem B candidates on **depth** alone.

**Check `pushed_at` against the actual commit log before calling a project
alive.** This was got wrong with MIND hours after recording the same class of
error about Tududi's tracker.

Ruled out categorically, not to be re-proposed: **Nextcloud** (in any role),
**Donetick** (a broken Projects feature visible in the UI is not tolerable,
even if unused), and **Vikunja** as a destination — it holds the data because
nothing else does, not because it is the choice.

---

## Vikunja (https://vikunja.mathewcsims.uk) — DECOMMISSIONED

> **DECOMMISSIONED 2026-08-08.** Torn down because it was not being used —
> the interface objection recorded throughout the section below never
> resolved, and the search for a replacement closed without one (see "Task
> management" above). The final database held 11 tasks in 2 projects, which
> is its own verdict. Container, image, network, both Caddy site blocks,
> Uptime Kuma monitors #4 and #17, the `vikunja` and `vikunja-relay` public
> A records and the `vikunja-relay` NextDNS LAN rewrite are all gone;
> `vikunja/`, `vikunja-webhook-relay/` and
> `scripts/pass-create-vikunja-relay-secret.sh` were removed from this repo
> and survive only in git history. The section below is kept verbatim as the
> rebuild recipe.
>
> **THE DATA WAS DELETED, deliberately — this one differs from every other
> decommissioning in this file.** A final `VACUUM INTO` dump and a cold
> `tar.gz` were taken and placed in `db-dumps/decommissioned/` as usual, then
> **removed on request** the same day: 11 tasks in 2 projects was not worth
> keeping. They never reached Kopia — `db-dumps`' last snapshot was 02:00 and
> the archives were written at 09:58 — so there is **no copy anywhere**, and
> the only recoverable thing is the app's configuration, from git history.
> Kopia's `vikunja/db` and `vikunja/files` sources were set to `--manual` so
> their existing history ages out on the normal policy rather than failing
> nightly verification. The **Vikunja** and **VikunjaWebhookRelay** Proton
> Pass items were retained.
>
> Unwired from automation: `scripts/dump-databases.sh` (the sqlite dump and
> the `vikunja` entry in the post-dump health check) and
> `kopia-mac/backup.sh` (both snapshot sources). `pf-lockdown/` was narrowed
> from `{ 3923, 3456 }` to port 3923 alone, applied and verified the same day
> (6 rules, down from 8).
>
> **This teardown incidentally exposed a live security gap**: applying that
> narrowing revealed the pf anchor had not been loaded at all for weeks, a
> macOS update having silently stripped it from `/etc/pf.conf`. See
> "Restricting LAN-only ports" for the incident and the self-healing fix.

[Vikunja](https://vikunja.io) task management, holding private information —
built with more deliberate hardening than the other apps here, on request.
Single container, sqlite (no separate DB service/password to manage), on the
Mac like copyparty/Memos.

**Image is pinned by digest to `ghcr.io/go-vikunja/vikunja:2.3.0`, NOT the
"official" `docker.io/vikunja/vikunja` the upstream docs point at.** That Docker Hub
image is stale — last pushed at `1.1.0` (Feb 2026) — and does **not** include
fixes for several real CVEs disclosed since, most seriously a **CVSS 9.1
critical** (`GHSA-2pv8-4c52-mf8j`): an unauthenticated instance-wide data
breach chaining a link-share hash disclosure with a cross-project attachment
IDOR — just a link-share URL was enough to potentially exfiltrate or delete
files across every project on the instance, not just the shared one. Also
fixed by 2.3.0: a rate-limit bypass via spoofed `X-Forwarded-For`/`X-Real-IP`
(`CVE-2026-29794`), a TOTP brute-force bypass (`CVE-2026-35597`), a 2FA bypass
via CalDAV basic auth, and others — 2.3.0's own release notes cite "11
security fixes". Confirmed via `go-vikunja/vikunja`'s actual GitHub releases
(not the stale Docker Hub listing) that 2.3.0 is genuinely current. **If you
ever bump this version, check the releases/changelog for security fixes
first** — this app has a real, recent CVE history, pin deliberately.

**Hardened beyond Vikunja's own defaults**, all in `vikunja/compose.yaml`:
- `VIKUNJA_SERVICE_ENABLEREGISTRATION: "false"` — **from the very first boot**,
  never temporarily opened. Vikunja has no `INITIAL_ADMIN_EMAIL`-style
  bootstrap env var, but it does have a CLI: the admin account was created
  with `podman exec vikunja /app/vikunja/vikunja user create -u mat -e
  mat@mathewcsims.uk -p <password>` — the registration endpoint has never been
  reachable, not even for a moment. Use the same command (or `... user
  reset-password --direct`) to add or manage accounts later; there's no
  self-service signup or admin "invite" flow, by design.
- `VIKUNJA_SERVICE_ENABLELINKSHARING: "false"` — off by default. This is
  specifically the feature the CVSS 9.1 chain above entered through; even
  fully patched, unused attack surface isn't needed for a private-data
  instance. Flip to `"true"` (`podman compose up -d`, not `restart`) if you
  deliberately want to share a project by link later.
- `VIKUNJA_SERVICE_IPEXTRACTIONMETHOD`/`TRUSTEDPROXIES` — same class of
  setting as copyparty's `xff-src`/`rproxy` and FreeScout's
  `APP_TRUSTED_PROXIES`: without it, Vikunja can't distinguish real client IPs
  from the podman gateway's, which breaks rate-limiting (limits would apply to
  "the proxy" instead of real clients) and is the exact shape of the spoofed-
  header rate-limit bypass CVE on older versions. Scoped to RFC1918 ranges
  (matching copyparty's `xff-src: lan`), not a single hardcoded IP.
- `VIKUNJA_RATELIMIT_ENABLED: "true"` (off by default upstream) — IP-based,
  10/min specifically on login/register/password-reset.
- `VIKUNJA_CORS_ENABLE: "false"` — this exists for the desktop app, which
  isn't in use; our reverse-proxied web UI is same-origin, no CORS involved at
  all, so disabling it is free attack-surface reduction.
- Caddy adds HSTS, `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`,
  and a `Referrer-Policy` — originally added for this site specifically, now
  applied to every site via a shared snippet (see the [hardening
  pass](#hardening-pass-copyparty-nimbus-caddy-memos) below).
- `VIKUNJA_SERVICE_ENABLETOTP` is left **on** (Vikunja's default) — not
  forced, but available: turn on 2FA for your account yourself under Settings
  whenever you want it.
- `VIKUNJA_SERVICE_TIMEZONE: Europe/London` (+ standard `TZ: Europe/London`)
  — Vikunja defaults to `GMT`, which doesn't observe BST, so for roughly half
  the year (late March–late October) server-side time was effectively an hour
  off real local time. This affects the API's serialized timestamps and
  anything computed server-side (reminder-email timing, recurring-task
  regeneration) — Vikunja's own maintainers describe the frontend as trusting
  the API to return correctly-zoned dates and just rendering whatever it's
  given, so a wrong server zone shows up as wrong times in the browser too,
  not just in the backend. Redeployed and confirmed healthy (no "unknown time
  zone" startup error — some minimal Docker images lack the IANA tz database
  entirely; this one has it built in) and the API stayed fully responsive
  afterwards.

**A genuine image quirk, not a security thing:** `ghcr.io/go-vikunja/vikunja`
is minimal — no shell, no `wget`/`curl` at all inside it (smaller attack
surface, but means the `wget`-based healthcheck pattern used elsewhere in this
repo doesn't work here). It has its own `vikunja healthcheck` CLI subcommand
instead, confirmed working before using it. Also: unlike copyparty (which runs
as root inside its container and benefits from podman-machine's automatic
root→host-user remap on macOS), Vikunja's image always runs as a fixed
non-root UID inside the container — the bind-mounted `./files`/`./db` need to
actually be owned by that UID for it to write to them. On this Mac (rootless
podman via the *remote* client), `podman unshare` isn't available to fix that
directly; used a throwaway container instead:
```sh
podman run --rm -v "$PWD/files:/files" -v "$PWD/db:/db" docker.io/library/alpine:latest \
  chown -R 1000:1000 /files /db
```

**To bring it up (mirrors copyparty):**
1. **Mac:** `cd vikunja && podman compose up -d`.
2. Create the admin account (see above) — do this before exposing it publicly.
3. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and reload Caddy.
4. **DNS:** add an explicit `A` record for `vikunja` → the Pi's WAN IP at the
   registrar (there is no blanket wildcard covering `*.mathewcsims.uk` — every
   hostname in this repo has its own individually-created record, added via
   the DigitalOcean API).
5. **NextDNS rewrite**: add `vikunja.mathewcsims.uk` → `10.0.1.19`, same as
   the other apps, for clean access from inside your own network.
6. Watch `docker compose logs -f caddy` (in `pi-reverse-proxy/`) for the cert,
   then visit `https://vikunja.mathewcsims.uk`.

---

## Speedtest Tracker (https://speedtest.mathewcsims.uk) — DECOMMISSIONED (was LAN-only, on the Pi)

> **DECOMMISSIONED 2026-08-04.** Torn down for lack of use. Container,
> image, network attachment, the Caddy site block, the Uptime Kuma monitor
> and the DNS records are all gone; `speedtest-tracker/` was removed from
> this repo and survives only in git history. The section below is kept
> verbatim as the rebuild recipe. A final SQLite dump (3,135 results,
> integrity-checked) and a cold `tar.gz` of the whole data directory live in
> `db-dumps/decommissioned/` on the Pi, and the **SpeedtestTracker** Proton
> Pass item was deliberately retained — between them, everything needed to
> stand this back up still exists. The LAN-gate idiom this app introduced
> outlived it: its rationale now lives at the top of
> `pi-reverse-proxy/Caddyfile`, where the seven remaining LAN-gated sites
> reference it.


[Speedtest Tracker](https://github.com/alexjustesen/speedtest-tracker) — periodic
internet speed tests, charted over time. Runs on the **Pi**, like Nimbus, both
for resilience and because it's measuring the Pi's own connection, so it
should live on the box that's online regardless of the Mac's state.

**Unlike every other app in this repo, access is LAN-only, not
internet-facing-with-a-login.** Same pattern as `mc37.mathewcsims.uk` (the
DrayTek router admin): a real public DNS record (its own individually-created
`A` record — there is no blanket wildcard covering `*.mathewcsims.uk`) and
Caddy-issued Let's Encrypt cert exist, but `pi-reverse-proxy/Caddyfile`'s
`speedtest.mathewcsims.uk` block gates on `remote_ip private_ranges` and
`abort`s any non-LAN source before it ever reaches the app — confirmed by
inspecting Caddy's live JSON config (`docker exec caddy wget -qO-
http://127.0.0.1:2019/config/`), not just assumed from the Caddyfile text.

**Image**: `lscr.io/linuxserver/speedtest-tracker`, pinned to an exact version
tag (`1.14.5` at time of writing). The original first-party
`ghcr.io/alexjustesen/speedtest-tracker` image is **deprecated** — its own
maintainer handed image builds to LinuxServer.io as of v0.20.0 (confirmed via
the project's README and the maintainer's own deprecation issue,
[#1224](https://github.com/alexjustesen/speedtest-tracker/issues/1224)).
Checked GitHub Security Advisories for both repos: none published. (Two
release notes are oddly titled "CVE release"/"CVE PATCH" — read the actual
diffs directly and they're unrelated minor fixes, not real disclosed
vulnerabilities.)

**Hardening, all in `speedtest-tracker/compose.yaml`:**
- `APP_KEY` generated once with `openssl rand -base64 32` (prefixed
  `base64:`) — this is **not** auto-generated by the image (confirmed against
  both the app's own docs and LinuxServer's changelog, which explicitly made
  it a hard requirement as of 2024-06-07); leaving it blank breaks the app.
- `ADMIN_NAME`/`ADMIN_EMAIL`/`ADMIN_PASSWORD` set explicitly from first boot
  — same reasoning as Vikunja's CLI-created admin: the documented hardcoded
  default (`admin@example.com` / `password`) is never reachable, not even
  briefly.
- `PUBLIC_DASHBOARD: "false"` (also the default) — kept off deliberately even
  though only LAN clients can reach the app at all: "LAN" includes anyone
  your Wi-Fi password reaches, not just you.
- The app's own `ALLOWED_IPS` env var is **deliberately not used** — with no
  documented trusted-proxy/`X-Forwarded-For` config for this app, it would
  only ever see Caddy's own container IP as "the client" behind a reverse
  proxy, not real LAN clients. The actual access-control decision has to
  happen at the network edge (Caddy's `remote_ip` check against the real
  connecting IP), not inside the app — same class of reasoning as copyparty's
  `xff-src`/Vikunja's `TRUSTEDPROXIES`, just resolved the opposite way here
  since this app has no equivalent setting to configure correctly.
- `TZ`, `APP_TIMEZONE`, and `DISPLAY_TIMEZONE` all set to `Europe/London`
  explicitly — belt-and-braces since the app's own docs and the LinuxServer
  base-image docs don't fully agree on which one actually governs what (see
  the [Vikunja timezone fix](#vikunja-httpsvikunjamathewcsimsuk) above for why
  this repo now sets timezone explicitly everywhere rather than trusting a
  default).
- Security headers and the general per-IP rate-limit zone (see the
  [hardening pass](#hardening-pass-copyparty-nimbus-caddy-memos) above) apply
  here too, on top of the LAN-only gate — defense in depth even though WAN
  clients can't reach it at all.
- Tests run every 15 minutes (`SPEEDTEST_SCHEDULE`, your choice — higher
  resolution than the default, at the cost of more frequent bandwidth used
  just for testing); results older than 90 days are auto-pruned
  (`PRUNE_RESULTS_OLDER_THAN`) so the sqlite DB doesn't grow unbounded.
  Changing either needs `docker compose up -d` (not `restart`) — this moved
  out of the settings UI into env-var-only config as of the app's v0.20.0.

**A genuine quirk, not a security thing:** the LinuxServer image runs as a
fixed non-root `PUID`/`PGID` (1000:1000, matching the Pi's own `mathew` user)
inside the container, unlike the podman-on-macOS apps elsewhere in this repo
where root auto-maps to the host user. On plain Docker there's no such
auto-remap, so `~/speedtest-tracker/config` must exist and already be owned
by `1000:1000` **before** the first `docker compose up` — `mkdir -p
~/speedtest-tracker/config` on the Pi (as the `mathew` user, who already is
uid/gid 1000) does this correctly with zero extra steps; letting Docker
create it as root first and fixing ownership after is the harder path.

**To bring it up:**
1. **Pi:** `mkdir -p ~/speedtest-tracker/config`, then copy the
   `speedtest-tracker/` folder over (`scp -r`) and `docker compose up -d`.
2. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy` (no Dockerfile change, so a restart is
   enough — see the [Operations](#operations) section for when a rebuild is
   needed instead).
3. **DNS:** add an explicit `A` record for `speedtest` → the Pi's WAN IP at
   the registrar — there is no blanket wildcard, so every new subdomain needs
   its own record, added via the DigitalOcean API.
4. **NextDNS rewrite**: add
   `speedtest.mathewcsims.uk` → `10.0.1.19`, same as every other app, so LAN
   devices resolve straight to the Pi rather than round-tripping out to the
   WAN IP and back in (NAT hairpinning) — some routers don't support that
   loopback path at all.
5. Visit `https://speedtest.mathewcsims.uk` from a LAN device and log in with
   the admin credentials from `speedtest-tracker/.env`.

---

## Fizzy (https://fizzy.mathewcsims.uk) — LAN-only

[Fizzy](https://www.fizzy.do), 37signals' open-source Kanban board, used as
the **backlog**: someday / now / done / never triage. The other two tiers of
the task setup are Super Productivity (below) and Tasks.org on the phone and
watch — see "Task management" for why it is three tools.

Single container, SQLite under `/rails/storage`, no DB sidecar — its own
deployment guide ships no database service. Image pinned by digest because
upstream publishes a rolling `:main` tag rather than versioned releases.
Verified arm64-native, so no emulation on the M4.

**LAN/tailnet-gated at Caddy**, matching docs, paperless, author and fj. It
holds a private backlog and Tailscale already covers access from away.

**Registration hardening comes free, and must not be undone.** Fizzy runs in
single-account mode by default and closes signups permanently as soon as the
first account exists — the same posture Vikunja needed
`ENABLEREGISTRATION=false` for. **Never set `MULTI_TENANT=true`.** Until the
first account is created, signups are OPEN to anyone who can reach the
hostname; the LAN gate is the only thing standing in front of that window.

**It runs as uid 1000, so it cannot bind port 80.** Thruster (the front-end
in `./bin/thrust ./bin/rails server`) defaults to port 80 and crash-loops
with `listen tcp :80: bind: permission denied`. Upstream's example compose
publishes 80/443 and works only because plain Docker there grants the
capability. Fixed with `HTTP_PORT=8080` and a `3600:8080` mapping, rather
than running the container as root and undoing the image's own privilege
separation.

**TLS_DOMAIN and DISABLE_SSL are both deliberately unset.** `DISABLE_SSL`
switches off `config.assume_ssl` AND `config.force_ssl` together
(`config/environments/production.rb:76-83` derives both from it), losing
HSTS and secure cookies. Leaving both unset is Rails' documented pattern
behind a terminating proxy: `assume_ssl` stops `force_ssl` bouncing the
forwarded request into a redirect loop, while `force_ssl` keeps the security
headers.

**Mail — the first working SMTP in this repo.** Every other app here leaves
it commented out; Fizzy needs it, because sign-in is a magic link or
6-character code and the alternative is reading codes out of the container
log forever. Credentials live in the shared **"Proton SMTP"** Pass item
(`self-hosted@mathewcsims.uk`, `smtp.protonmail.ch:587`, STARTTLS),
deliberately general-purpose rather than per-app. **The field names do not
line up** — Pass uses `SMTP_SERVER`/`SMTP_TOKEN`, Rails wants
`SMTP_ADDRESS`/`SMTP_PASSWORD` — so `compose.yaml` maps them, keeping the
Pass item reusable. Proton requires the From address to match the address
the token was issued against, so `MAILER_FROM_ADDRESS` is not independently
configurable.

**Deploy with BOTH Pass items**, or every send fails authentication:

```
./scripts/pass-deploy.sh fizzy Fizzy "Proton SMTP"
```

**Web Push is unavailable** — no VAPID keys, which cannot be generated
before first boot. Not needed: Fizzy's notifications are activity-based
(comments, assignment), not the due-date reminders this stack relies on. To
add later:

```
podman exec -it fizzy bin/rails runner 'k=WebPush.generate_key; puts k.private_key, k.public_key'
```

### Mobile: install the PWA, not the app-store app

**The official Fizzy Android app does not work with a self-hosted instance.**
It offers no server-URL field, 37signals ship it as a Turbo Native wrapper,
and nothing in their docs suggests otherwise — the same shape as Super
Productivity's Android client, whose URL is compile-time hardcoded. Do not
install it expecting it to reach this instance.

**Fizzy is a proper PWA, and that is the supported mobile route.** Verified
on this instance: `/manifest` returns 200 with `display: standalone`,
`scope: /` and three icons (192, 512, and a 192 maskable), all of which
resolve; `/service-worker` is a real route (it 302s to sign-in when logged
out, which is expected).

To install on Android:

1. Open **Chrome** — not Firefox, whose PWA handling on Android is weaker.
2. Go to `https://fizzy.mathewcsims.uk` and **sign in first.** Installing
   from the signed-out page pins a login screen and registers the service
   worker against it.
3. Chrome menu (**⋮**) → **Add to Home screen** (it may say **Install app**).
4. Accept the name, confirm.
5. It appears with the Fizzy icon and opens standalone — no address bar, no
   browser chrome. It is pointed at this instance because that is the URL it
   was installed from; there is no server setting to get wrong.

**It only loads when Tailscale is up.** Fizzy is LAN/tailnet-gated, so away
from home the phone needs Tailscale connected, exactly like paperless, docs
and fj. Worth knowing that a PWA with a service worker can render a cached
shell when it cannot reach the server, so a Fizzy that looks loaded but
empty or stale usually means Tailscale is down rather than the instance
being broken — check Tailscale before checking the server.

**Backups.** `fizzy/storage` is a Kopia source, and
`scripts/dump-databases.sh` dumps `production.sqlite3` nightly. The other
three SQLite files it writes (`production_cable`, `production_cache`,
`production_queue`) are Solid Cable/Cache/Queue infrastructure — regenerated
on boot, worthless in a restore, deliberately not dumped.

---

## Super Productivity (https://sp.mathewcsims.uk) — LAN-only

[Super Productivity](https://super-productivity.com), the middle tier:
detailed day-to-day tasks with reminders, too heavy for the Fizzy backlog
and not recurring chores.

**THIS CONTAINER HOLDS NO DATA.** It is nginx serving a static Angular
bundle. Super Productivity is local-first: tasks live in each browser's
IndexedDB and are synced by the app itself over WebDAV. There is no
server-side database, no accounts, and nothing here to back up — losing this
container loses nothing. There is deliberately no volume, because adding one
would imply otherwise.

**There is also no login, at all.** Unlike every other app here, there is no
second line of defence behind the proxy: Caddy's LAN gate and the
`pf-lockdown` rule on port 3601 are the entire access control.

### The sync target, and why it shares a hostname

Sync goes to copyparty's `/sp-sync` volume at
`https://sp.mathewcsims.uk/sp-sync/` — the **same origin** as the app, via a
Caddy route to copyparty on 3923. That is the load-bearing design decision:

- Super Productivity syncs **from the browser**, so a target on another
  hostname makes every request cross-origin.
- copyparty exposes only `--acao`/`--acam` and has **no control over
  `Access-Control-Allow-Headers`**, while SP sends `Depth` and `If-Match`,
  which are not CORS-safelisted. Preflight would fail. SP even has a
  dedicated `PotentialCorsError` for exactly this.
- Same-origin removes the problem instead of configuring around it.

**The path must never be rewritten** — `handle`, never `handle_path`.
copyparty puts its own absolute paths in PROPFIND `<D:href>` (verified:
`<D:href>/sp-sync/</D:href>`) and the client resolves against them, so
stripping the prefix would point every subsequent request at nothing.

### Things checked in source rather than assumed

- **`--daw` is set as a VOLFLAG, not globally.** Without it copyparty
  answers a PUT over an existing file by inventing a new filename instead of
  overwriting, so every save becomes a new file and sync never converges.
  Set globally it would change overwrite semantics for the **entire** file
  server including your documents; copyparty's own help says to prefer the
  volflag. Needed because SP does not send `x-oc-mtime`.
- **`vague-403` was KEPT.** The old note here said to remove it the moment a
  WebDAV volume returned, on the assumption that WebDAV clients wait to be
  challenged. SP's client sets `Authorization: Basic` on every request, and
  an unauthenticated PROPFIND against this config returns **401, not 404** —
  both measured, not inferred.
- **No `dav-port` needed.** `--ua-nodav` defaults to `^(Mozilla/|...)`, so a
  browser looks like a non-WebDAV client — but that governs GET-versus-HTML
  behaviour, not method dispatch. PROPFIND, MKCOL, PUT, overwrite, GET and
  DELETE all verified working with a browser user-agent on the normal port.
- **copyparty returns no `ETag`, and that is fine.** SP's own XML parser
  does `etag: lastModified` — it deliberately uses `getlastmodified`, which
  copyparty does return on every entry.
- **The bind mount is load-bearing.** A `[/sp-sync]` volume with no matching
  mount in `copyparty/compose.yaml` still "works": copyparty logs
  `type=overlay` and writes into the container's ephemeral layer, losing
  every task on the next recreation, silently. Caught during setup by
  reading that log line.

**The account** is `spsync`, scoped `rwmd` to `/sp-sync` only, defined in
`copyparty/cfg/accounts-spsync.conf` — rendered from its **own** Pass item
because the agent token can create Pass items but not update the existing
"Copyparty" one. copyparty merges `[accounts]` across auto-loaded `*.conf`
files; verified in a throwaway container before relying on it.

### Configuring the sync, field by field

Do this **once per browser/device** — the settings live in that browser's
own storage, not on the server, so a new laptop or a cleared profile needs
it again.

1. Open `https://sp.mathewcsims.uk` and go to **Settings** (cog, bottom-left)
   → **Sync & Export** → **Sync**.
2. **Sync provider** → `WebDAV`. A warning appears calling generic WebDAV
   "experimental and provided as-is" — expected; that is upstream's blanket
   caveat about WebDAV servers differing, not a problem with this one.
3. **Server URL** — `https://sp.mathewcsims.uk`
   The field is labelled *Nextcloud Server URL* even for plain WebDAV; the
   form is shared with the Nextcloud provider. Enter the origin only, with
   no trailing path.
4. **Username** — `spsync`
5. **App Password** — the `PASSWORD` field of the **"Copyparty SP Sync"**
   Proton Pass item. (Also labelled for Nextcloud; it is just the password.)
6. **Sync Folder Path** — `/sp-sync`
7. **Encryption** — a deliberate choice, see below. Default is off.
8. Leave everything under **Advanced** (Sync interval, Manual sync only) at
   its defaults unless you want otherwise.
9. Press **Sync now**.

**Verify it actually worked** — from the Mac:

```
ls -la ~/self-hosted/copyparty/sp-sync/
```

You want `sync-data.json` with a current timestamp and a non-trivial size
(~30 KB with a real task list). `.hist/` is copyparty's own index and is
expected. An empty directory means the sync did not run, whatever the app
said.

### Encryption is off by default — decide, don't drift

The synced blob is **plaintext**: a `pf_2__` prefix followed by readable
JSON containing every task. Turning on SP's encryption passphrase makes it
opaque to anyone who obtains the `spsync` credentials.

Not enabled here, on the grounds that the file already sits behind a LAN
gate, a volume-scoped account, and full-disk encryption, and Kopia encrypts
it again before it reaches Backblaze — while a lost passphrase means losing
every task with no server-side recovery, because there is no server that
understands the data. That reasoning is worth re-checking if the blob ever
leaves this setup.

### The `/sp-sync/` browsing trap

**Do not browse to `https://sp.mathewcsims.uk/sp-sync/` in a browser to
check on the files.** You will get a broken half-loaded Super Productivity
app, not copyparty's file listing, and it looks exactly like the sync being
broken when it is fine.

Cause: Super Productivity is a PWA whose service worker is registered at
scope `/`, and its `ngsw.json` navigation rules treat any path *without a
dot in the last segment* as a navigation to serve the app shell for.
`/sp-sync/` qualifies; the shell then requests `chunk-*.js`, `main-*.js`,
`manifest.json` and fonts relative to `/sp-sync/`, and copyparty 404s all of
them. Confirmed in Caddy's access log.

**The sync itself is unaffected, and that was checked rather than assumed:**
`sync-data.json` contains a dot, so it is excluded from navigation handling,
and the only `dataGroup` in `ngsw.json` (`api-freshness`) matches
`api.github.com`, `gitlab.com/api` and `*.atlassian.net` — nothing under
`/sp-sync/` is ever cached or intercepted.

To browse the synced files, use the **copyparty hostname**, which carries no
service worker:

```
https://cp.mathewcsims.uk/sp-sync/
```

Note that `curl` will happily return 200 for both — curl has no service
worker. Only a real browser hits this, which is why it is written down.

**Backups.** `copyparty/sp-sync` is a Kopia source — the only durable copy,
since everything else is browser IndexedDB that a cleared cache wipes.

---

## Ghost blog (https://blog.mathewcsims.uk)

[Ghost](https://ghost.org) — replaces paid Ghost(Pro) hosting. Two
containers, Mac like copyparty/Memos/Vikunja: `ghost` (the app) and
`blog-db` (MySQL 8). Unlike every other app here, Ghost's own docs are
explicit that **MySQL 8 is the only supported database in production** —
sqlite works in dev but isn't QA'd for production, so this needed a real DB
sidecar (same pattern as Nimbus's `nimbus-db`), not the sqlite-in-one-container
approach used elsewhere.

**Image**: `ghost:6.53.0`, pinned by digest, not just an exact version tag
(a tag can still be repushed to a different digest; the digest can't).
Independently checked GitHub's advisory database (`api.github.com/advisories?
ecosystem=npm&affects=ghost`, not just trusted a summary): several real past
CVEs — critical SQL injection in the Content API, a critical cache-poisoning
XSS disclosed literally the day before this was deployed, RCE via malicious
themes, CSRF/2FA bypasses — every one's vulnerable range caps out at or below
6.36.0, so 6.50.0 is patched against all of them. The theme-RCE class
specifically only applies if you install untrusted third-party themes —
deliberately staying on the bundled default (Casper/"source") theme, not
installing anything else, keeps that whole risk class off the table rather
than just "currently patched."

**The setup-wizard race condition — a real, documented risk for self-hosted
Ghost:** there's no CLI/env-var way to seed the owner account; the *first*
visitor to reach `/ghost/` completes setup and becomes the owner, and Ghost's
own community/security discussions confirm this has bitten people who exposed
an unconfigured instance publicly. Closed here by sequencing: brought Ghost up
reachable only via the Mac's LAN IP (`10.0.1.14:2368`, no Caddy wiring yet),
completed the owner-account setup immediately via the Admin API's own
`POST /ghost/api/admin/authentication/setup/` endpoint (confirmed
`{"setup":[{"status":true}]}` afterward, meaning the endpoint is now
permanently closed to anyone else), and only *then* added the
`blog.mathewcsims.uk` Caddyfile block — the setup window was never open to
the internet, not even briefly.

**Mail is not optional here, unlike everywhere else in this repo.** Beyond
staff invites and password-reset — genuinely necessary since there's no other
account-recovery path for a self-hosted instance — it turned out Ghost also
requires email verification for every *new session login* by default (a
"new device detected" 6-digit code flow), so without SMTP configured, normal
day-to-day admin login doesn't work at all, not just password recovery.
Configured with Proton Mail (STARTTLS on 587 — `mail__options__secure` is
deliberately `"false"`, since Ghost/Nodemailer treats 587 as a
STARTTLS-upgrade connection, not implicit TLS).

**A genuine Admin-API gotcha, not a security thing:** Ghost's session-cookie
auth enforces a same-origin CSRF check (`session.origin` must match the
request's `Origin` header, and once set on a session it's compared on every
subsequent request) — scripting the login flow with `curl` requires sending
a consistent `Origin: https://blog.mathewcsims.uk` header from the *first*
request onward, or later requests 401 with no useful error message pointing
at the real cause. Confirmed directly from Ghost's own source
(`session-service.js`'s `cookieCsrfProtection`), not guessed. The 2FA
verification flow itself is `PUT /ghost/api/admin/session/verify/` with
`{"token": "<6-digit code>"}`, reusing the same session cookie the initial
`POST /session/` call set — also not documented anywhere obvious, found by
reading Ghost's actual route registration
(`web/api/endpoints/admin/routes.js`).

**No curl/wget in this image** (confirmed by exec'ing in) — the healthcheck
uses `node`'s own `http` module instead (`node -e "require('http').get(...)"`),
since `node` is the one thing guaranteed present in a Node.js app image.

**Hardening, all in `pi-reverse-proxy/Caddyfile`'s `blog.mathewcsims.uk`
block:** the shared security-headers snippet and general rate-limit zone
(same as every other app), plus a dedicated strict zone
(`rl_blog_auth`, 15 requests/min/IP) scoped to
`/ghost/api/admin/session/*` and `/ghost/api/admin/authentication/*` —
supplementary to Ghost's own built-in login/password-reset limit (5/hour/IP,
per its docs), same defense-in-depth reasoning as every other app here.
Verified live: rapid POSTs to `/ghost/api/admin/session/` return real
responses then a plain empty-bodied `429` (Caddy's own signature — Ghost's
own limiter returns a structured JSON error instead, so the two are
distinguishable in logs).

**Importing the existing post from Ghost(Pro):** the paid-hosted site had
exactly one real post. Its content was recovered from the site's own public
RSS feed (`content:encoded` includes full post HTML, not just an excerpt)
combined with a screenshot for the parts the feed fetch didn't capture before
the source went briefly unreachable, then recreated via the Admin API
(`POST /ghost/api/admin/posts/?source=html`, which accepts raw HTML and lets
Ghost convert it to its native Lexical format itself — confirmed the
kg-bookmark-card figure in the original HTML correctly became a native
Lexical `bookmark` node, not just inert embedded markup). Original
`published_at`, tags, slug, and feature image/caption were all preserved.
The Admin API key used for this was a temporary Custom Integration, created
via the Admin UI (Settings → Integrations) since integration creation itself
isn't exposed via the API — deleted again immediately after the import, since
it had no further purpose and a full-admin-scoped key sitting around
unused is needless standing risk.

A quirk worth knowing: Ghost auto-seeds a "Coming soon" placeholder post,
timestamped at first-boot time — since Ghost sorts by `published_at`
descending, this placeholder (today's date) outranked the imported post
(backdated to Dec 2025) on the homepage until it was deleted
(`DELETE /ghost/api/admin/posts/<id>/`).

**Web analytics (Stats page), backed by Tinybird:** Ghost's native Stats
page is powered by [Tinybird](https://tinybird.co), its official analytics
partner since Ghost 6.0. Cookie-less by design — visitor uniqueness uses a
daily-rotating salted signature, not cookies or raw-IP geolocation, so no
cookie-banner obligation per Ghost's own docs.

- **Extra services**: `traffic-analytics` (long-running — anonymizes/salts
  visitor identifiers before forwarding page-hit events to Tinybird) and
  two one-time setup jobs, `tinybird-sync`/`tinybird-deploy` (deploy Ghost's
  bundled Tinybird schema — datasources, pipes, materialized views — into
  your workspace). All under the `analytics` Compose profile
  (`podman compose --profile analytics up -d`), adapted from Ghost's own
  official reference (github.com/TryGhost/ghost-docker) for this repo's
  split topology: their reference assumes Caddy is co-located with Ghost on
  one host, reaching `traffic-analytics` by container name with no
  published port; ours runs Caddy on the Pi, so `traffic-analytics` gets a
  published port on the Mac's LAN IP instead (`10.0.1.14:3001`), matching
  every other Mac-resident service, with a path-based route in
  `pi-reverse-proxy/Caddyfile` (`/.ghost/analytics/**` → that port,
  verbatim pattern/rewrite from Ghost's own reference Caddy snippet).
- **Skipped `tb login` entirely** — Ghost's documented setup flow runs an
  extra `tinybird-login` container through the Tinybird CLI's browser/
  device-code OAuth flow first. That flow reliably failed to complete in
  this environment (device-code method never picked up browser approval
  even after confirming; the browser-callback method's `localhost:<port>`
  redirect isn't reachable from inside a podman container's own network
  namespace, and installing the CLI natively on the Mac to work around that
  network mismatch got the callback listening correctly but the flow still
  never completed — root cause not identified, possibly a Tinybird-side
  quirk unrelated to this stack). Route not pursued further: `tb` has a
  fully-documented, non-interactive alternative — `--token`/`TB_TOKEN`
  (confirmed against Tinybird's own CI/CD docs) takes priority over any
  `.tinyb` login-flow file. `tinybird-deploy` here authenticates with the
  **workspace admin token**, copied directly from the Tinybird dashboard's
  Settings → Tokens page — no CLI login needed at all, and no compose
  service equivalent to `tinybird-login` exists in this repo's version.
- **A real bug hit and fixed**: `tinybird__workspaceId` is easy to get
  wrong if you're not careful about *which* ID a Tinybird admin token's
  payload actually encodes — the token itself is a JWT-shaped string
  (`p.<base64 payload>.<signature>`) whose decoded payload has fields `u`
  (the actual workspace ID) and `id` (the *token's own* ID, not the
  workspace's) — using the wrong one here caused every Stats-page query to
  fail with a genuine `403 Forbidden` from Tinybird (Ghost's own logs
  showed `Error in Tinybird API request to .../v0/pipes/api_top_pages.json:
  Response code 403`), even though the events were being ingested into
  Tinybird successfully the entire time (confirmed via `traffic-analytics`'
  own logs showing "response received" for real browser-triggered events).
  Don't decode the token by hand to get the workspace ID — confirm it
  properly instead: `podman compose --profile analytics run --rm
  --entrypoint sh tinybird-deploy -c "cd /data/tinybird && tb --token
  $TINYBIRD_ADMIN_TOKEN --host $TINYBIRD_API_URL info"` prints the
  authoritative `workspace_id` directly.
- **A benign warning, not a real gap**: `traffic-analytics` logs
  `HmacValidationDisabled` on startup. No corresponding env var/config
  exists in the service's own `.env.example` or public config — this looks
  like it's relevant to Ghost(Pro)'s multi-tenant hosted infrastructure
  (verifying which hosted site a request belongs to), not something a
  single self-hosted instance needs to configure.
- **Fetching the tracker token** (created automatically by `tinybird-deploy`,
  needed for `traffic-analytics`' own config) needs care: never print a
  live Tinybird token to a terminal/log/file directly — fetch and write it
  to `.env` in one step instead:
  ```python
  import json, urllib.request
  # read TINYBIRD_ADMIN_TOKEN from .env, GET /v0/tokens, filter name=="tracker",
  # write TINYBIRD_TRACKER_TOKEN=<value> back into .env — see git history for
  # the exact script used here if you need to redo this.
  ```

**To bring it up:**
1. **Mac:** `cd blog && podman compose up -d` — starts on `10.0.1.14:2368`,
   MySQL alongside it. **Do not wire up Caddy yet.**
2. Complete owner setup immediately via the Admin API before doing anything
   else (see SETUP.md's race-condition note above for the exact call) —
   don't use the web wizard for this on a from-scratch deploy, since that
   would mean briefly leaving `/ghost/` reachable pre-setup once Caddy is
   added.
3. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
4. **DNS:** nothing to add — `blog` already had its own individually-created
   `A` record from before the migration (previously pointing at Ghost(Pro)'s
   hosting), and it turned out to already be repointed at the Pi's WAN IP by
   the time of deployment, so no separate action was needed here. There is no
   blanket wildcard covering `*.mathewcsims.uk` — every hostname has its own
   individually-created `A` record, added via the DigitalOcean API — so don't
   assume an existing record, repointed or otherwise, exists for every domain
   being migrated onto this stack later.
5. **NextDNS rewrite**: add `blog.mathewcsims.uk` → `10.0.1.19`, same as
   every other app.
6. Log in at `https://blog.mathewcsims.uk/ghost/` with the owner credentials
   from `blog/.env`.
7. **Web analytics (optional)**: create a Tinybird account/workspace at
   [cloud.tinybird.co](https://cloud.tinybird.co), copy the workspace admin
   token and workspace ID into `blog/.env` (`TINYBIRD_ADMIN_TOKEN`,
   `TINYBIRD_WORKSPACE_ID` — get the ID via `tb info`, not by decoding the
   token, see the note above) and the API host (`TINYBIRD_API_URL`,
   matching the region chosen at signup), then:
   ```sh
   podman compose --profile analytics run --rm tinybird-sync
   podman compose --profile analytics run --rm tinybird-deploy
   # fetch the resulting "tracker" token into .env — see the Python
   # snippet above, never print it directly
   podman compose --profile analytics up -d
   ```
   Then copy the updated `pi-reverse-proxy/Caddyfile` to the Pi and restart
   Caddy again, for the `/.ghost/analytics/**` route.

---

## Landing page (https://mathewcsims.uk)

[LittleLink](https://github.com/sethcottle/littlelink) — a link-in-bio style
page for the bare apex domain (not a subdomain, unlike everything else in
this repo). Genuinely static: nginx serving plain HTML/CSS, no backend, no
database, no auth — confirmed by reading upstream's own Dockerfile, not
assumed. About as close to zero attack surface as a self-hosted app gets.

**No published Docker image exists upstream** — the project ships only a
Dockerfile you build yourself, no Docker Hub/GHCR listing. Ours fetches an
exact tagged release (`v3.10.0`) at build time rather than tracking `main`,
so a rebuild later doesn't silently pick up unreviewed upstream changes; the
whole tarball, checked for GitHub Security Advisories (none published), gets
extracted into the nginx web root, then `landing-page/index.html` (this
repo's own content — name, tagline, links) is copied on top, overwriting
just that one file.

**Apex domain, not a subdomain — different DNS handling from every other
app here.** There is no blanket wildcard covering `*.mathewcsims.uk` — every
hostname in this repo, including the bare apex (`mathewcsims.uk` itself), has
its own individually-created `A` record pointed directly at the Pi's WAN IP,
added via the DigitalOcean API.

**To bring it up:**
1. **Mac:** `cd landing-page && podman compose up -d` — starts on
   `10.0.1.14:3080`.
2. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
3. **DNS:** an explicit `A` record for the bare domain — see above.
4. **NextDNS rewrite**: add `mathewcsims.uk` → `10.0.1.19`, same as every
   other app.

---

## Karakeep (https://karakeep.mathewcsims.uk)

[Karakeep](https://github.com/karakeep-app/karakeep) — self-hosted
bookmark-everything app: links, notes, images, full-page archival (via
monolith), video archiving (yt-dlp), full-text search (Meilisearch),
AI-based tagging.

**Migrated from a separate deployment, not set up fresh.** It previously ran
at `~/ScaleTail/services/karakeep/` (a personal clone of
[tailscale-dev/ScaleTail](https://github.com/tailscale-dev/ScaleTail)'s
template collection), reachable only via a Tailscale sidecar
(`network_mode: service:tailscale`, no other ingress at all). Moved into
this repo and onto the public `karakeep.mathewcsims.uk` hostname instead,
same architecture as every other Mac app here — Caddy on the Pi terminates
TLS, proxies to plain HTTP on the Mac. The Tailscale sidecar and its auth
key were dropped entirely; existing data (`./data`, `./meilisearch-data`)
was moved in unchanged, not recreated, so bookmarks/assets/search index all
survived the move.

**Image, pinned:** the original deployment floated on
`ghcr.io/karakeep-app/karakeep:release`. Checked GitHub security advisories
directly: 5 disclosed (4 high — two SSRF protection bypasses, a stored-XSS
via the Reddit plugin bypassing DOMPurify, an XSS in the assets feature —
plus one low-severity auth-timing user-enumeration issue). All fixed by
`0.32.0`, which is what was already running (confirmed via image build
date) and also the latest release at migration time — pinned explicitly
now instead of left floating.

**Hardening decisions made (see `karakeep/compose.yaml`):**
- `DISABLE_SIGNUPS=true` — was `false` (open) under the Tailscale-only
  deployment, safe there since only tailnet devices could reach the signup
  page at all. Closed now that this is a public hostname.
- `RATE_LIMITING_ENABLED=true` — off by default upstream. Supplemented by a
  Caddy-layer zone on the actual NextAuth credentials-callback path
  (`/api/auth/callback/credentials`), same defense-in-depth pattern as
  every other app's auth endpoint in this repo.
- `NEXTAUTH_SECRET`/`MEILI_MASTER_KEY` carried over unchanged from the old
  deployment (not regenerated) — preserves existing sessions and
  Meilisearch's access to the migrated index.

**To bring it up on a fresh machine:**
1. **Mac:** `cd karakeep && podman compose up -d` — starts on
   `10.0.1.14:3000`.
2. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
3. **DNS:** needs its own explicit A record for `karakeep.mathewcsims.uk` —
   no blanket wildcard exists (confirmed against the actual DNS zone during
   the ArchiveBox work), every single-hostname app here has its own record.
4. **NextDNS rewrite**: add `karakeep.mathewcsims.uk` → `10.0.1.19`, same as
   every other app.

**CRITICAL CVE triage + mitigations (2026-07-26).** Trivy's weekly scan
flagged 14 CRITICAL findings after the postcss-fix digest bump above, all
base-OS or transitive deps with no published fix yet. Rather than treat
Trivy's package list at face value, checked reachability by inspecting
the running container directly (`apt-cache rdepends`, checking which
binaries actually run):

- **Genuinely reachable, mitigated:** `libaom3`/`libxml2` (pulled in by
  ffmpeg's `libavcodec`/`libavformat` and `librsvg2` — real decoders for
  attacker-supplied images/video from bookmarked pages) and
  `CVE-2026-59873` (node-tar gzip-bomb DoS — confirmed `tar@7.5.12` is a
  real dependency of the workers app). No patch exists yet, so
  `compose.yaml` now sets `mem_limit: 2g`, `pids_limit: 512`, and
  `cap_drop: [ALL]` on the `web` service — doesn't fix the CVEs, caps the
  blast radius of a crash/resource-exhaustion attempt to a contained
  restart. Verified live post-deploy: all workers started clean, crawler
  connected to the chrome sidecar, health checks passing, real bookmark
  traffic flowing with no capability-related errors.
- **Checked and ruled NOT reachable, no mitigation applied:**
  `libmbedcrypto7` (CVE-2025-47917, CVE-2026-34873, CVE-2026-34875) only
  reaches the image via `librist4`, ffmpeg's RIST broadcast-streaming
  protocol — nothing in Karakeep's workflow ever invokes it; the 4
  perl-base CVEs and the glib CVE — base-image cruft, no evidence the
  app shells to perl or does GDBus introspection; `CVE-2023-45853`
  (zlib) — the vulnerable function is minizip's zip-*writer*, contrib
  code Debian's zlib1g package doesn't build in; the two Go stdlib CVEs
  — no Go binary actually runs here (`monolith` is Rust, `yt-dlp` is
  Python); `GHSA-7rqj-j65f-68wh` (@auth/core email-homoglyph bypass) —
  signups are disabled, so that self-registration path doesn't exist.

---

## HealthLog (https://healthlog.mathewcsims.uk) — DECOMMISSIONED

> **DECOMMISSIONED 2026-08-07.** Torn down once a better solution covered
> what was left: medication tracking had already moved to MedTimer on
> 2026-08-04, and the remaining tracking was not being used. Containers,
> images, network, the Caddy site block, the Uptime Kuma monitor and the DNS
> records are all gone; `healthlog/` and
> `scripts/pass-create-healthlog-secrets.sh` were removed from this repo and
> survive only in git history. The section below is kept verbatim as the
> rebuild recipe. THE HEALTH DATA IS KEPT: a final `pg_dump` (133 tables,
> 38,587 measurements, 116 workouts) and a cold `tar.gz` of the whole app
> directory including the Postgres datadir live in
> `db-dumps/decommissioned/` on the Mac, both restore-tested out of
> Backblaze B2 and matched by sha256. The **HealthLog** Proton Pass item was
> deliberately retained.


[HealthLog](https://github.com/MBombeck/HealthLog) — self-hosted health
tracker: medication reminders (over ntfy/Web Push/Telegram/APNs), vitals
(weight, blood pressure, glucose, sleep), mood/wellness questionnaires
(WHO-5, PHQ-9, GAD-7). Added 2026-07-26 as a self-hosted replacement for
Pillo (medication reminders specifically). **PolyForm Noncommercial 1.0.0
licensed** — source-available, not OSI open-source; free for this personal
noncommercial use, not a "true" open-source project.

**Why this one over the alternatives considered:** researched live rather
than from memory (self-hosted medication trackers are a niche category
with a lot of abandoned/toy projects) — Helse's medication-reminder
feature ("Treatments") isn't shipped yet; MedStats has zero stars, no
Docker path, looks abandoned. HealthLog stood out: actively developed
(weekly releases), real Docker Compose deployment, and — the deciding
factor — reminders go out over **ntfy**, which this repo already runs, so
no new notification infrastructure was needed.

**Samsung Health sync — works, via an undocumented bridge (confirmed
live 2026-07-26).** HealthLog's "Google Health" integration is the
Google Health API (Fitbit/Pixel data — Samsung Health is mentioned
nowhere in its docs), and the first connect attempt failed with Google's
`FAILED_PRECONDITION: The account is not linked to Google Health` —
meaning the Google account had no Fitbit/Google Health profile at all,
NOT a config problem on this side (the OAuth code exchange itself
succeeded). The fix and the resulting data path, working end to end:

1. Install the **Fitbit app** on the (Samsung) phone, signed into the
   same Google account — no Fitbit hardware needed; completing setup is
   what creates the Google Health profile the API precondition demands.
2. Grant the Fitbit app read access to Samsung Health's data types in
   **Health Connect** (Samsung Health has written to Health Connect
   since v6.22.5) — the same bridge HealthLog's own docs describe for
   Garmin.
3. Reconnect in HealthLog (Settings → Google Health) — the failed
   attempt leaves nothing stale; the app cleanly rejects replayed OAuth
   callbacks.

So: Samsung Health → Health Connect → Fitbit app → Google Health API →
HealthLog. Confirmed syncing in practice. All four scopes granted
read-only (activity/fitness, health metrics, profile, sleep); Google
tokens are stored app-encrypted in Postgres, not raw.

**Architecture:** same pattern as every other Mac-hosted app — Caddy on
the Pi terminates TLS and proxies to plain HTTP on the Mac
(`healthlog/compose.yaml`, port 3200 — not the Karakeep-conventional 3000,
already taken). Two containers: the HealthLog app itself and a Postgres
16 sidecar (`./pgdata`, not a bare podman-managed volume — bind-mounted
like every other app's data dir here, so it's a plain directory Kopia can
back up, not something opaque to the backup pipeline).

**This is the one app in this repo where access control was treated as
the top priority above all else**, given what it stores:

- **Registration is permanently disabled** (`app_settings.singleton
  .registration_enabled = false`, confirmed directly via `psql` against
  the running container, not just trusted from the admin UI) — the only
  path to an account is now gone entirely. Passkey-only login (WebAuthn),
  no password fallback configured.
- **The first-registrant-becomes-admin race**: HealthLog has no setup
  token — whoever registers the very first account on a fresh instance
  becomes admin, and there's no way to control who that is except being
  first. The real risk: the moment Caddy requests this hostname's TLS
  cert, it's published to public Certificate Transparency logs and gets
  probed by bots within minutes — "DNS hasn't propagated yet" is not a
  real defense window. Handled by bringing the real public hostname up
  from the start (WebAuthn passkeys are bound to the exact origin at
  registration — a LAN-IP-first-then-switch-domains approach would have
  produced an unusable passkey) but with a **temporary Caddy IP-allowlist**
  (home public IP + the `10.0.1.0/24` LAN range — both needed, since
  NextDNS's split-DNS rewrite sends home devices straight to the Pi's LAN
  IP, never touching the WAN path, so Caddy sees a private address for
  local requests) blocking everyone else until registration was complete
  and disabled. Confirmed live before removing it: a public-IP-only
  allowlist actually blocked a request from the Mac itself, for exactly
  the LAN-rewrite reason above — the fix needed both ranges.
- **Container hardening**: `no-new-privileges:true` on both containers
  (upstream's own recommendation), plus `mem_limit`/`pids_limit` on each
  (1g/256, matching the mitigation pattern used for Karakeep's unfixed
  CRITICAL CVEs elsewhere in this doc) as general defense-in-depth, not a
  response to any specific found issue here.
- **Caddy-layer rate limiting** on `/api/auth/*` (HealthLog has no
  documented built-in rate limiting on its own auth endpoints) — broad
  path match since the exact WebAuthn route names aren't documented
  anywhere; worth narrowing once confirmed against real traffic patterns.
- Data is encrypted at rest by the app itself (AES-256-GCM, its own
  `ENCRYPTION_KEY`) independent of anything at the infrastructure level.

**Secrets** (`POSTGRES_PASSWORD`, `ENCRYPTION_KEY`, `API_TOKEN_HMAC_KEY`,
all 32-byte hex): the "HealthLog" Proton Pass item, created via
`scripts/pass-create-healthlog-secrets.sh` — run under Mathew's own
pass-cli session, not the agent's (agent PATs are read-only by design, see
above), same pattern as `scripts/pass-create-vikunja-relay-secret.sh`.

**To bring it up on a fresh machine:**
1. **Mac:** `./scripts/pass-create-healthlog-secrets.sh` (once, if the
   Pass item doesn't already exist), then
   `./scripts/pass-deploy.sh healthlog HealthLog` — starts on
   `10.0.1.14:3200`.
2. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
3. **DNS:** `./scripts/dns-digitalocean.sh add healthlog <Pi's public IP>`
   (the zone's apex CAA records already cover every subdomain, no
   per-subdomain CAA record needed) and
   `./scripts/dns-nextdns.sh add healthlog.mathewcsims.uk 10.0.1.19`.
4. **First run only:** complete passkey registration as the very first
   user immediately (you're the admin from that point on), then disable
   registration in the admin panel — verify with `podman exec
   healthlog-postgres psql -U healthlog -d healthlog -c "SELECT
   registration_enabled FROM app_settings;"` rather than trusting the UI
   toggle alone. Only remove any setup-time IP-allowlist in the Caddyfile
   after that's confirmed.

**Medications moved off this app to MedTimer (2026-08-04).**
Accumulated rough edges and bugs — the 15-minute reminder loop above, plus
enough smaller ones to erode confidence — but the deciding factor was that
a medication's dose can't be altered after it's created. The upstream
tracker was checked before concluding that's a design gap rather than a
reportable bug: nothing matching `dose` or `dosage` covers editing a dose
post-creation. The near misses are all something else — #316 (inventory),
#650 (JSON intake import skipping entries), #214 (`calculateCompliance`
ignoring `daysOfWeek`/`intervalWeeks`), #664 (web push firing a day late
for a 23:45 dose). So it's untracked upstream and not something a version
bump resolves. **Deliberately not filed** — this is a decision to move on,
not a feature request, and filing one would imply waiting for it.

[MedTimer](https://github.com/Futsch1/medTimer) (MIT, Android, F-Droid +
Play Store, fully offline, no account) takes over medications specifically.
Two reasons it closes the gap: dose changes and tapering are a documented
use case — one reminder per amount, each bounded to its own active period,
so a dose change is an end-date plus a start-date and the history stays
intact — and reminders fire from the phone's own `AlarmManager` rather than
a server-side tick fanned out over ntfy. That removes the entire class of
failure the reminder loop above came from: no cron tick, no push relay, no
channel-specific dedup ledger to get wrong.

**MedTimer's backups do NOT go through Kopia — deliberately.** Its
automatic backup writes a timestamped JSON to a directory chosen through
Android's Storage Access Framework, so any DocumentsProvider (SMB to the
NAS, WebDAV to copyparty) *could* drop it straight into an existing Kopia
source with no change to `kopia-mac/backup.sh`. Not doing that. Backup is
**Syncthing → Proton Drive** instead, handled entirely off this repo's
infrastructure. It keeps phone-originated health data out of the Mac's
backup path, and the copyparty variant in particular would have cost the
`vague-403` setting in `copyparty/cfg/copyparty.conf`. (That setting was
briefly removed on 07-08 because it broke Orgzly's WebDAV auth, and
**restored on 08-08** when organice was decommissioned and nothing here spoke
WebDAV again. The reasoning for keeping MedTimer's backup off this
infrastructure is unchanged and stands on its own.)

So if you're reading `kopia-mac/backup.sh` wondering why there's no
MedTimer source: there isn't one, and there shouldn't be.

---

## msims.link — URL shortener, runs on the Pi

[chhoto-url](https://github.com/SinTan1729/chhoto-url) — self-hosted URL
shortener, MIT licensed, ~6MB image, SQLite built in (no DB sidecar
container). Chosen over Shlink/YOURLS/Kutt specifically for the resource
footprint — Babel already runs several small services, and this is a
personal single-user tool that didn't need Shlink's heavier analytics
stack or YOURLS/Kutt's extra DB containers. Live manifest checked before
choosing: publishes real `arm64`/`arm/v7` images, not just amd64.

**Own domain, not a mathewcsims.uk subdomain** — a link shortener needs
to actually be short. `msims.link` was picked after checking real
availability + actual cart pricing (not registry base-rate tables, which
miss premium-tier pricing entirely) across `.link`/`.cc`/`.to`/`.gd` —
`.to` and `.gd` both turned out expensive despite looking like the
obvious short-domain picks (`.to` is $51.80/yr at even a budget
registrar), landing on `.link` at $4.48 first year / $8.98/yr after.
Registered through the same DigitalOcean account as `mathewcsims.uk`
(`scripts/dns-digitalocean.sh` generalized to accept `DOMAIN=` for any
zone in the account, not just the original hardcoded one).

**Security review done before deploying** (read the actual Rust source,
not just docs/marketing pages — this is the standard this repo holds
every self-hosted app to):
- Password/API key: Argon2-hashed (`CHHOTO_HASH_ALGORITHM=Argon2`
  below) — the app verifies against a stored hash; plaintext is never
  held server-side once configured. Real signed+encrypted session
  cookies (`actix-session`, secret key regenerated fresh on every
  container restart so a restart invalidates all sessions,
  `SameSite=Strict`).
- Gap found and compensated for at the Caddy layer: **no built-in
  brute-force protection on `/api/login` at all** — confirmed by reading
  `backend/src/services/post.rs` directly; a failed attempt just logs a
  warning, no lockout or delay. Same class of gap already found and
  mitigated the same way for Memos/Karakeep — a Caddy rate-limit zone on
  that path.
- `cookie_secure` is hardcoded `false` in the app's own source
  (`backend/src/main.rs`), with no env var to override it — their docs
  are upfront that the app does no transport encryption itself and
  expects a TLS-terminating reverse proxy in front. Accepted: Caddy is
  the only path in, the container is never directly reachable (no
  `ports:`, `pi-shared` network only).
- `CHHOTO_PUBLIC_MODE` left at its default (`Disable`) — this is a
  personal shortener, not something anyone else should be able to
  create links through.

**Bare-domain redirect, not the shortener's own login screen.** Visiting
`https://msims.link/` redirects (real HTTP 301, at the Caddy layer) to
`https://mathewcsims.uk` rather than showing a random visitor the
shortener's branded login prompt. This needed `CHHOTO_CUSTOM_LANDING_DIRECTORY`
set (pointing at `./landing`, a trivial fallback page) — **without** it,
chhoto-url serves its actual admin/login UI directly at `/` with no
separate path at all, confirmed live (`/admin/manage/` 404s otherwise).
Setting it moves the real dashboard to `/admin/manage/`, which Caddy's
own exact-path redirect (`path /`, not a prefix) doesn't touch. The
`./landing/index.html` content is essentially never seen in practice —
Caddy intercepts `/` before the request ever reaches the container — it
exists purely as a fallback if that Caddy rule is ever removed.

**A real, if brief, false alarm during setup** worth recording since it
looked exactly like a serious routing bug: right after the Caddy
restart, short links appeared to 404 through the public URL while
working fine hitting the container directly. Root cause was TLS
certificate issuance (ACME `tls-alpn-01`) still settling for the
brand-new `msims.link` cert — tested too soon after `docker compose
restart caddy`. No code or config was actually broken; a second test a
few seconds later confirmed everything worked. Worth remembering next
time a fresh-hostname deploy looks broken immediately after a Caddy
restart.

**Container hardening**: `no-new-privileges:true`, `cap_drop: [ALL]`,
`pids_limit: 32`, `mem_limit: 128m`. The memory limit initially wasn't
enforced — Raspberry Pi OS Bookworm doesn't compile in cgroup memory
support by default (confirmed live: `docker compose up` warned "Your
kernel does not support memory limit capabilities... Limitation
discarded"). Fixed 2026-07-27 by appending `cgroup_enable=memory
cgroup_memory=1` to `/boot/firmware/cmdline.txt` (the real, authoritative
boot cmdline on Bookworm — `/boot/cmdline.txt` is a vestigial placeholder
that says as much) and rebooting Babel. One wrinkle worth remembering:
after the reboot, `/proc/cgroups` still showed the `memory` line as
absent, and `/proc/cmdline` showed a `cgroup_disable=memory` flag
injected by the Pi's own firmware ahead of the fix's flags (source not
fully identified — possibly baked into the board's device tree) — both
looked like the fix hadn't worked. It had: `/proc/cgroups` is a legacy
cgroup-v1-only view, and Babel runs cgroup v2 exclusively, where
`/sys/fs/cgroup/cgroup.controllers` and `.../cgroup.subtree_control` are
the actual source of truth — both listed `memory` as available. Confirmed
working by redeploying chhoto-url and checking
`docker inspect chhoto-url --format '{{.HostConfig.Memory}}'`, which now
returns `134217728` (128MB) instead of being silently discarded.

**No container-level healthcheck** — this image genuinely has no shell
at all (confirmed live: `docker exec chhoto-url sh` → "executable file
not found"), so nothing exists inside the container to run a
wget/curl-based check with. Uptime Kuma, checking
`https://msims.link/api/version` from outside, is the real health
signal here, same as it is for every other app in this repo.

**Secrets** (`CHHOTO_PASSWORD`/`CHHOTO_API_KEY`, both pre-hashed Argon2
strings, plus the plaintext originals for actual use) live in the
"MsimsLink" Proton Pass item, created via
`scripts/pass-create-msims-link-secrets.sh` — run under your own
pass-cli session, not the agent's (agent PATs are read-only by design).
Requires the `argon2` CLI (`brew install argon2`) — the exact hashing
invocation chhoto-url's own docs recommend. Note: the `argon2` CLI has
its own undocumented input-length limit — the 128-character API key
upstream's docs suggest generating is too long for it ("Provided
password longer than supported in command line utility"); the script
generates 64 characters instead (still ~380 bits of entropy).

**To bring it up on a fresh machine:**
1. **Mac:** `./scripts/pass-create-msims-link-secrets.sh` (once, if the
   Pass item doesn't already exist).
2. **Pi:** `scp -r msims-link mathew@babel:~/msims-link`, then
   `./scripts/pass-deploy-remote.sh msims-link mathew@babel
   /home/mathew/msims-link MsimsLink` (use the real absolute remote
   path, not `~` — it expands on the *local* shell before ever reaching
   SSH, confirmed live the hard way).
3. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
4. **DNS:** `DOMAIN=msims.link ./scripts/dns-digitalocean.sh add @
   <Pi's public IP>`, `DOMAIN=msims.link ./scripts/dns-digitalocean.sh
   add-caa @ issue "letsencrypt.org."` (note the trailing dot — DO's API
   rejects the value without it, unlike the display format it shows back
   in `list-caa`), and `./scripts/dns-nextdns.sh add msims.link
   10.0.1.19`.
5. **Backups:** `../msims-link/data:/data/msims-link:ro` was added to
   `kopia-server/compose.yaml`'s volume list — redeploy `kopia-server`
   after adding a new app here, same as every other Pi app's data
   directory.

---

## Apprise API (https://apprise.mathewcsims.uk) — LAN-only, runs on the Pi

[Apprise API](https://github.com/caronc/apprise-api) — a small HTTP front-end
for the [Apprise](https://github.com/caronc/apprise) notification library.
Register one or more notification-target URLs under a "config key", then
anything on the LAN can `POST /notify/<key>` to fan a message out to every
target under that key, without the caller needing to know the underlying
webhook. Runs on the **Pi**, not the Mac, same resilience reasoning as
Nimbus/Speedtest Tracker: the Mac being down is exactly the kind of thing
you want a notification about, so the notifier can't depend on it being up.

**Chosen over building notifications straight into each app** because most
apps here (Karakeep, backup scripts, etc.) have no native Discord/webhook
support of their own — Apprise gives a single stable endpoint any script can
`curl`, with the actual Discord webhook kept out of every individual app's
config.

**Image**: `caronc/apprise` (NOT `caronc/apprise-api` — that name isn't a
real published image), pinned to `1.5.1` by tag and digest.

**No built-in authentication at all** (confirmed in Apprise's own README) —
anyone who can reach it can read/write stored config and send notifications
through it. `pi-reverse-proxy/Caddyfile`'s `apprise.mathewcsims.uk` block
gates on `remote_ip private_ranges` and `abort`s any non-LAN source, same
LAN-only pattern as Speedtest Tracker — there's no in-app auth option to
layer on top of instead.

**Discord webhook, never stored in this repo:** the "Apprise" Proton Pass
item holds one field, `DISCORD_WEBHOOK` (the raw
`https://discord.com/api/webhooks/<id>/<token>` URL from Discord's own
integration settings). `scripts/pass-seed-apprise.sh` fetches it, converts it
to Apprise's own `discord://<id>/<token>/` scheme, and feeds it — over stdin
the whole way (ssh stdin → a remote `read` loop → a pipe into `docker exec`'s
stdin, landing in `apprise/scripts/seed.py`) — into a `POST /add/<key>` call
against the container. Nothing secret ever touches a Bash argument, an env
var, or a file. Re-run this script any time the webhook or the ntfy publisher
token is rotated in Pass; `/add/<key>` *replaces* that key's config, so it is
idempotent.

**Three config keys, deliberately (since 2026-08-08):**

| Key | Targets | Who posts to it |
|---|---|---|
| `self-hosted` | Discord **+** ntfy topic `alerts` (default priority) | everything in this repo — backups, DB dumps, Trivy, watchdogs, relays |
| `fail2ban` | ntfy topic `fail2ban` at `priority=low`, **no Discord at all** | `pi-fail2ban/notify-apprise.sh`, `caddy-abuse` jail only |
| `fail2ban-urgent` | Discord **+** ntfy topic `alerts` at `priority=high` | `pi-fail2ban/notify-apprise.sh`, every other jail |

The split exists because the `caddy-abuse` jail bans at machine rate, not
human rate — 119 lifetime bans with 54 concurrently banned as of 2026-08-08,
and three ban/unban notifications inside a twenty-minute window while this
was being changed. On the shared key that buried every alert that actually
needed reading.

**But not all jails are that**, hence the third key rather than one quiet
route for all of fail2ban. `sshd` has fired **zero** times in its lifetime,
and password auth is off (`pi-sshd/`), so an `sshd` ban means something is
attempting SSH auth that should not be — rare, and worth interrupting for.
`notify-apprise.sh` routes by jail name, and **defaults unknown jails to the
urgent key**: a jail added later should be loud until somebody deliberately
decides it is noise, rather than quietly going missing. `fail2ban-urgent`
reuses the existing `alerts` topic rather than adding a third one, so there
is nothing new to subscribe to on the phone.

Both the topic and the priority live entirely on the Apprise-side target
URL, so retuning either is a re-seed and needs no change on the Pi.

**`priority=` is an Apprise ntfy URL argument** (`max`/`high`/`default`/
`low`/`min`), read off `NotifyNtfy.template_args` in the running container
rather than assumed. Worth knowing: it maps straight to the `X-Priority`
header and is **not** derived from the `type` a caller POSTs, so
`notify-apprise.sh` sending `type=failure` does not drag the notification
back up to a loud one. Verified live end-to-end — a test ban landed in
`cache.db` as `topic=fail2ban, priority=2` (ntfy's numbering: 1 min, 2 low,
3 default), where every earlier ban sits on `topic=alerts, priority=0`, and
Apprise's own log shows `Loaded 1 entries` for that key, i.e. no Discord
attempt at all.

**Ntfy is no longer optional to this script.** It used to fall back to
Discord-only if the "Ntfy" Pass item was missing; because the `fail2ban` key
has no Discord target, that fallback would now silently drop fail2ban
notifications on the floor instead. A missing or fieldless "Ntfy" item is a
hard error.

**To bring it up on a fresh machine:**
1. **Pi:** copy the `apprise/` folder over (`scp -r`) and
   `docker compose up -d` — joins `pi-shared`, no port published to the host
   at all (bring `pi-reverse-proxy` up first if `pi-shared` doesn't exist
   yet).
2. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
3. **DNS:** its own explicit `A` record for `apprise.mathewcsims.uk` — no
   blanket wildcard.
4. **NextDNS rewrite**: add `apprise.mathewcsims.uk` → `10.0.1.19`, same as
   every other app.
5. From the Mac (or anywhere with `pass-cli` access to the vault): run
   `./scripts/pass-seed-apprise.sh` to register both config keys. Note it
   `scp`s nothing — `apprise/scripts/seed.py` is bind-mounted from the Pi's
   own copy of the folder, so **copy that file over first if it has changed
   in the repo**, or the Pi will keep running the old one (this bit once:
   the pre-split `seed.py` hardcoded the `self-hosted` key, so both seed
   lines landed on it and left it empty until the file was copied across).
6. Test from a LAN machine:
   `curl -X POST https://apprise.mathewcsims.uk/notify/self-hosted -d 'body=test'`
   — a message should land in Discord within a couple of seconds. HTTP 200
   means every target under the key succeeded; a failed target gives 424.
   Repeat against `/notify/fail2ban` to check the quiet ntfy-only route.

**Notification formatting convention (color, icon, markdown).** The
registered Discord URL carries `?format=markdown&image=yes`
(`scripts/pass-seed-apprise.sh`) — confirmed directly from Apprise's own
`discord.py` source, not assumed: `image=yes` shows a small type icon in
the embed, `format=markdown` lets the `body` use `**bold**`/lists/`` `code`
``, and the embed's sidebar color is set automatically from whatever
`type` value (`info`/`success`/`warning`/`failure`) each `POST
/notify/self-hosted` call includes — this is generic Apprise/Discord
behavior, not something built here. Every notifier in this repo that feeds
this shared endpoint (`pi-unattended-upgrades/notify-reboot-required.sh`,
`vikunja-webhook-relay/relay.py`, and the backup/scan scripts) follows the
same convention: pick a `type` matching real severity, prefix the title with
a matching emoji (🚫/✅/⚠️/🔔) for at-a-glance scanning in a channel feed,
and send `format=markdown` with the body. Verified live: ban/unban,
reboot-required, and a signed Vikunja `task.overdue` test event all
rendered with the correct color/icon/markdown in Discord.
`pi-fail2ban/notify-apprise.sh` still follows the convention but no longer
feeds this key — it posts to `/notify/fail2ban`, which has no Discord target,
so its `type` now only sets the ntfy icon.

**Uptime Kuma does NOT go through this endpoint at all** — it bundles its
own Apprise CLI and shells out to it directly from its own Notification
settings UI (see the Uptime Kuma section below), a structurally separate
path. This formatting convention doesn't apply to Kuma's alerts; that
would need reconfiguring inside Kuma's own UI if wanted.

---

## ntfy (https://ntfy.mathewcsims.uk) — runs on the Pi, ON TRIAL

[ntfy](https://github.com/binwiederhier/ntfy) — self-hosted push
notification server, trialled (2026-07) as a richer delivery target than
the Discord webhook: real priority levels (distinct sounds/vibrations per
severity), markdown, attachments, and **action buttons** (a notification
can carry up to three buttons — open a URL, or fire an arbitrary HTTP
request, e.g. a "Retry" on a backup-failure alert). Discord keeps working
unchanged alongside; Apprise fans every `/notify/self-hosted` out to
**both** (see `scripts/pass-seed-apprise.sh` — the ntfy target is registered
from the "Ntfy" Pass item's `PUBLISHER_TOKEN`, into topic `alerts`).

**Topics in use:**

| Topic | Priority | Content |
|---|---|---|
| `alerts` | default | the general firehose, mirroring Discord |
| `alerts` | `high` | fail2ban bans from any jail *except* `caddy-abuse` (i.e. `sshd`), also mirrored to Discord |
| `fail2ban` | `low` | `caddy-abuse` bans/unbans only, **not** mirrored to Discord — see the Apprise section above for why |

Both are served by the same write-only `publisher` token: `ntfy access`
confirms it holds `write-only access to topic *`, and the `mathew` admin user
reads every topic, so adding a topic needs no ACL change at all. This is also
the first thing here that ntfy delivers and Discord does not, so the 2026-07
trial is now load-bearing rather than purely parallel.

**Image**: `binwiederhier/ntfy:v2.26.3`, pinned by digest. **Emergency-bumped
2026-07-23 from v2.14.0** — the first Trivy scan (see below) surfaced
CVE-2026-39087, CVSS 9.8, unauthenticated RCE via `parseActions`, exactly
the code path the action-buttons trial exercised. Fixed in v2.21+; patched
same day it was found, deployed and verified healthy with auth still
enforced before this doc was updated.

**Public, not LAN-gated** — phones must receive pushes away from home,
same reachability class as the Discord webhook it's trialling against.
Compensating controls: `NTFY_AUTH_DEFAULT_ACCESS: deny-all` (verified
live: anonymous publish → 403), so nothing is readable or writable
without an account, plus Caddy's per-IP rate limit.

**Accounts** (all in the "Ntfy" Pass item; created via
`docker exec ntfy ntfy user add`, passwords never on a command line —
passed via the `NTFY_PASSWORD` env var):
- `mathew` (admin) — web UI + phone app login.
- `publisher` (write-only, all topics) — what Apprise and scripts embed;
  its `PUBLISHER_TOKEN` can spam but never read anything.

**iOS caveat (deliberate)**: `NTFY_UPSTREAM_BASE_URL: https://ntfy.sh` —
Apple allows only APNs for background push, so the official ntfy.sh
relays a content-free "poll now" ping (message ID only, no title/body);
the app then fetches the real message from this server. Android (F-Droid
build) connects straight here with no third party involved.

**Apprise integration notes**: Apprise's ntfy plugin passes through
priority, tags/emoji, markdown, attachments, and even action buttons
(`actions=` as a per-target URL parameter — static per target). Truly
per-message buttons need a direct publish to this server instead
(`X-Actions` header, JSON array format — the simple comma format can't
carry JSON bodies for `http` actions; hit exactly this during setup).

**Trial status**: evaluating app-side experience (per-priority sounds
are per-priority only, NOT per-topic — a known limitation accepted going
in) before deciding whether anything moves off Discord. Rollback = remove
the ntfy line from `pass-seed-apprise.sh`, re-run it, `docker compose
down` the ntfy folder, drop the DNS record and Caddy block.

**To bring it up on a fresh machine**: copy `ntfy/` to the Pi,
`docker compose up -d`, add the Caddy block + `ntfy` A record, recreate
the two users, store them in Pass, re-run `pass-seed-apprise.sh`.

---

## Uptime Kuma (https://status.mathewcsims.uk) — runs on the Pi

[Uptime Kuma](https://github.com/louislam/uptime-kuma) — self-hosted uptime
monitoring and public status page for every hostname in this repo. Runs on
the **Pi**, not the Mac, for the same resilience reason as Nimbus: the thing
telling you an app is down needs to still be up itself if the Mac isn't.

**Image**: `louislam/uptime-kuma`, pinned to `2.4.0` by tag and digest.
Checked Uptime Kuma's own published security advisories: 4 historical CVEs
found, all patched well before this release.

**Login is Socket.IO-based, not a REST path** (confirmed by reading
`server/server.js` and `server/socket-handlers/general-socket-handler.js` at
this exact tag) — the usual Caddy path-matched rate-limit zone used for
every other app's auth endpoint in this repo doesn't apply here, and Kuma's
own rate limiter is a single global counter, not per-IP. Only the general
per-IP zone (`status.mathewcsims.uk`'s `general_ratelimit` import) covers
login attempts. **Enable Two-Factor Authentication in Settings after first
login** as the compensating control — this is genuinely important here,
more so than for the other admin-login apps in this repo.

**Notifications go through Kuma's OWN bundled Apprise CLI or its native
Discord provider (Settings → Notifications), not through the standalone
Apprise container above.** Kuma bundles its own `apprise` binary and shells
out to it locally (`server/notification-providers/apprise.js`) — routing
through the separate `apprise-api` container would just be an unnecessary
extra hop for Kuma's own alerts. The standalone Apprise container stays
useful for everything else that wants to fire a notification without
embedding a webhook of its own.

**Configured to use the native Discord provider, not Apprise — a deliberate
choice, not the default.** Confirmed by reading both providers' source
(`server/notification-providers/apprise.js` and `discord.js`): Kuma's own
Apprise integration never passes a notification-type flag to the `apprise`
CLI at all (only `-b`/body and `-t`/title), so every notification through
that path renders with the same flat blue/info color regardless of whether
a monitor went down or came back up — even with the shared Apprise
container's `?format=markdown&image=yes` (see the Apprise API section
above). The native Discord provider builds its own real embeds instead:
red (`#FF0000`) with a "❌ ... went down" title and structured fields
(service name, URL, went-offline timestamp, error) for DOWN; green
(`#00FF00`) with "✅ ... is up" and fields including downtime duration and
ping for UP. Uses the same raw Discord webhook URL as the standalone
Apprise container's Pass-stored `DISCORD_WEBHOOK` field, entered directly
into Kuma's own notification config (Message Format: "Normal (rich
embeds)"). Verified live: forced a real DOWN→UP cycle by temporarily
pointing the Landing Page monitor at a nonexistent path, confirmed both a
correctly red-colored DOWN embed and a green UP embed (with downtime
duration) arrived in Discord.

### Adding/managing monitors programmatically (Socket.IO)

Kuma **has no REST API for monitor CRUD** — `/api/monitors` just returns the
SPA's HTML, and `getStatusPageList` etc. are Socket.IO events, not routes.
Everything below therefore drives Kuma's own Socket.IO interface, which is
exactly what its web UI uses. **Do not write to `kuma.db` directly** — see
the SQLite incident in the Kopia section for why touching a live SQLite
database a running app has open is a bad idea.

Credentials live in the **"Uptime Kuma"** Proton Pass item:
`ADMIN_USERNAME`, `ADMIN_PASSWORD`, `TOTP_SECRET` (2FA is enabled, so the
secret is required to log in non-interactively) and `UPTIMEKUMA_APIKEY`.

Needs `python-socketio[client]` and `pyotp` — install into a throwaway venv
rather than polluting the system Python. The shape is:

```python
sio = socketio.Client()
sio.connect("https://status.mathewcsims.uk", transports=["websocket"])
sio.call("login", {"username": ..., "password": ...,
                   "token": pyotp.TOTP(TOTP_SECRET).now()})
# monitors arrive asynchronously on the "monitorList" event — you must
# sleep a few seconds after login before it's populated, it is NOT a
# return value.
sio.call("add", monitor_dict)                       # create a monitor
sio.call("saveStatusPage", (slug, cfg, icon, groups))  # update status page
```

**Build new monitors by cloning an existing one** of the same type and
overriding `name`/`url`/`keyword`/`hostname`. That inherits the established
conventions (60s interval, 60s retry, 3 retries, `notificationIDList`
pointing at the Discord notification) instead of guessing at ~100 fields.

**Gotchas, hit live when adding monitors:**
- A cloned monitor carries a **`maintenance`** key, which is a *runtime*
  field and not a database column. Kuma passes the object straight into an
  INSERT, so it fails with `table monitor has no column named maintenance`.
  Strip it (along with `id`, `childrenIDs`, `includeSensitiveData`,
  `forceInactive`, `dns_last_result`, `tags`).
- **`saveStatusPage`'s third argument (the icon) must not be `null`** —
  Kuma calls `.startsWith()` on it and throws
  `Cannot read properties of null (reading 'startsWith')`. Pass the page's
  existing `config.icon` (currently `/icon.svg`).

**A later round of monitor changes surfaced three more**, all the same class —
the monitor object Kuma *hands you* is not the shape it *accepts back*:

- The strip-list above was incomplete: **`pathName` and `screenshot`** are
  also runtime-only. Note `path` and `pathName` are separate keys (a list
  and a string), and Kuma returns camelCase while the columns are
  snake_case — so removing `path_name` does nothing.
- Don't discover these one error at a time. **Diff the monitor object
  against the real schema** and strip everything that isn't a column,
  keeping only the two Kuma legitimately converts (`accepted_statuscodes`
  → `accepted_statuscodes_json`, and `notificationIDList`, which writes to
  its own join table and is what carries the Discord notification):

  ```sh
  ssh mathew@babel 'python3 -c "
  import sqlite3
  c=sqlite3.connect(\"file:/home/mathew/uptime-kuma/data/kuma.db?mode=ro\",uri=True)
  print([r[1] for r in c.execute(\"PRAGMA table_info(monitor)\")])"'
  ```

- **`saveStatusPage`'s config must come from the authenticated
  `getStatusPage` event, NOT from `/api/status-page/<slug>`.** The public
  endpoint returns a trimmed, published view missing `id` and — critically
  — `domainNameList`, and without that array the save fails with a bare,
  unhelpful `{"ok": false, "msg": "Invalid array"}`. The *groups* still
  come from the public endpoint (it's the only place the current
  group→monitor structure is exposed); only the config comes from the
  socket event.

**Every one of these failures was atomic** — nothing partial was created —
so iterating on the error message is safe, if tedious.

**TOTP tokens can't be reused.** Two runs inside the same 30-second window
fail the second login with `authInvalidToken`, which looks like a
credentials problem and isn't. Wait for the next window before retrying.

**Tag conventions.** Every monitor carries `Homelab` plus **one tag naming
the machine it runs on** — `Heart of Gold` (Mac), `Babel` (Pi),
`Slartibartfast` (the third host, added 2026-07-30 with Immich; emerald
`#059669`). Adding a fourth host means adding a fourth tag. Tag events are
`getTags`, `addTag` (payload `{name, color, new: True}`) and
`addMonitorTag` (positional tuple: `(tagId, monitorId, value)`). Note the
tag goes with the machine the *monitored process* runs on — e.g.
`Owl document-viewer` is tagged `Heart of Gold` because the sidecar
container is on the Mac, even though Owl's own data lives there too.

**Every monitor must be tagged** — there should never be an untagged one.
Verify with:

```sh
ssh mathew@babel 'python3 -c "
import sqlite3
c=sqlite3.connect(\"file:/home/mathew/uptime-kuma/data/kuma.db?mode=ro\",uri=True)
print([r[0] for r in c.execute(\"SELECT m.name FROM monitor m LEFT JOIN monitor_tag mt ON mt.monitor_id=m.id GROUP BY m.id HAVING count(mt.tag_id)=0\")])"'
```

**`Memos (tailnet)` is deliberate, not stale.** It pings the OLD ScaleTail
Memos container that `Rep's Notes` (prospect-ukri-tus) was migrated from.
That instance is kept running on purpose, serving a link that forwards
visitors to the new one, for anyone who hasn't yet noticed the move. Do not
"clean it up" — it is monitored precisely because it still needs to be up.
Retire it only once the forwarding is no longer wanted.

**Status page conventions:** the `all` page ("All Services") has three
groups — `Services`, `Monitoring & infrastructure`, `Tailnet apps` — and
each is sorted **case-insensitively alphabetical** (which is why
`msims.link` sits between `Marque` and `Owl`, and `ntfy` after `Nimbus`).
Keep it that way: sort with `key=lambda m: m["name"].lower()` after
inserting. `saveStatusPage` replaces the whole group structure, so build it
from the current public endpoint
(`/api/status-page/all` → `publicGroupList`) and insert into that, rather
than constructing groups from scratch.

Verify afterwards against the **public** page, not the save's return value:

```sh
curl -s https://status.mathewcsims.uk/api/status-page/all | python3 -m json.tool
```

**No env-var-based admin bootstrap exists for this app** (confirmed —
unlike Nimbus's `INITIAL_ADMIN_EMAIL`/`PASSWORD`), so the very first visit
to `https://status.mathewcsims.uk` runs Kuma's own setup wizard: choose an
admin username and password there directly, nothing to configure in
`compose.yaml` for this.

**To bring it up on a fresh machine:**
1. **Pi:** copy the `uptime-kuma/` folder over (`scp -r`) and
   `docker compose up -d` — joins `pi-shared`, no port published to the host
   at all.
2. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
3. **DNS:** its own explicit `A` record for `status.mathewcsims.uk` — no
   blanket wildcard. No NextDNS rewrite is needed here (unlike the
   LAN-only apps) since this one is meant to be fully public.
4. Visit `https://status.mathewcsims.uk`, complete the setup wizard (admin
   username/password), then:
   - Enable 2FA in Settings.
   - Enable "Trust Proxy" in Settings → General, so Kuma logs/displays real
     client IPs rather than Caddy's own container IP.
   - Add a monitor for each public hostname in the [Apps](README.md#apps)
     table.
   - Wire up a notification provider (native Discord webhook, or the
     bundled Apprise CLI) under Settings → Notifications, and attach it to
     each monitor.

### Monitoring layout (full audit, 2026-07-23)

28 monitors (as of 2026-07-28 — started at 22, ntfy/Tailscale webhook
relay/Wanderer added since), all wired to the Discord notification, all
tagged (Homelab + host tag — HealthLog, msims.link, and Wanderer had
silently drifted from this despite it being the documented convention
right here; caught 2026-07-28, all three tagged retroactively via
`addMonitorTag`, worth double-checking against this doc rather than
assuming future additions get it right), all with TLS cert-expiry alerts
on, retries=3, 60s retry cadence while failing, and re-notification every
10 consecutive failed checks (so a long outage keeps pinging rather than
alerting once). `wanderer-memo-relay` is deliberately NOT in Kuma — it
has no HTTP endpoint at all (a pure outbound SSE listener + Owl poster,
no published port), same shape as `contact-sync`/`trivy-scan`'s launchd
jobs, neither of which are monitored here either. Its `restart:
unless-stopped` plus its own container logs are the operational
visibility for it.

- **App-truth checks, not just "HTTP 200"** wherever the app exposes a
  real health endpoint: Karakeep `/api/health` (keyword `"status":"ok"`),
  HealthLog `/api/health` (keyword `"status":"ok"`, added 2026-07-26),
  msims.link `/api/version` (keyword `Chhoto URL`, added 2026-07-27),
  Vikunja `/api/v1/info` (keyword `"version"`), all three Memos instances
  `/healthz` (keyword `Service ready`), Apprise `/status` (keyword `OK`),
  Ghost `/ghost/api/admin/site/`, Speedtest Tracker `/api/healthcheck`,
  Forgejo `/api/healthz`, TimeTagger via oauth2-proxy's own `/ping`,
  Wanderer's own root page (keyword `wanderer`, matching its `<title>`,
  added 2026-07-28 — no dedicated health endpoint found on it).
- **Expected-status monitors** for auth-gated/POST-only surfaces: Kopia
  accepts `401` (its normal unauthenticated answer); the Vikunja relay and
  the Tailscale webhook relay (added 2026-07-25) both accept `501` — both
  only implement `do_POST`, so a GET proves the Caddy→relay chain without
  needing a real signed payload.
- **Non-HTTP**: TCP check on Forgejo's git-over-SSH port (10.0.1.14:2222),
  ICMP ping for the Mac itself (catches host-down vs app-down), and ICMP
  pings for the four tailnet-only ScaleTail apps (CyberChef, Memos,
  StirlingPDF, Transmute) via their Tailscale 100.x addresses — the Pi is
  on the tailnet. golink is the one unmonitored service (not visible from
  the Pi's tailnet).
- **Intervals**: 60s for the key public services, 180s for LAN-only and
  tailnet ones.
- **Status page** (`/status/all`): **27 of the 29 active monitors**, in three
  groups (Services / Monitoring & infrastructure / Tailnet apps). Wanderer
  added to the Services group. Each group's monitor order is alphabetical
  (case-insensitive) — re-sorted 2026-07-28 after Wanderer landed at the
  end instead; keep new additions sorted into place rather than appended.
  **One active monitor is deliberately NOT on the page: Docs.** Being LAN-only
  is not the reason — BookStack and Paperless are LAN-only and are listed. It is
  simply a personal-authoring surface whose existence there adds nothing; add it
  if that changes. (organice was the other such monitor until it was
  decommissioned on 2026-08-08. Counted 2026-08-07;
  this line previously said "all 28", which was already drifting.)

**API caveat (learned doing this):** Kuma's API keys only authenticate the
read-only endpoints (`/metrics`, badges). ALL write operations (monitors,
notifications, status pages) go through its Socket.IO interface, which
needs the real admin login — username + password + a TOTP code (2FA is
enabled) via the `login` event, after which the returned JWT can be
reused via `loginByToken` for the rest of the session. The "Uptime Kuma"
Pass item holds `UPTIMEKUMA_APIKEY`, `ADMIN_USERNAME`, `ADMIN_PASSWORD`,
and (added 2026-07-28) `TOTP_SECRET` — the base32 secret from the
authenticator enrollment, stored as a plain field (not pass-cli's
dedicated TOTP field type, which `item totp` looks for and won't find
here), so the code is generated with a direct RFC 6238 implementation
(stdlib `hmac`/`hashlib`/hardcoded to 30s/6-digit) rather than that CLI
subcommand. Storing this closes the loop the agent previously couldn't:
before this, adding/editing a monitor needed Mathew's live 6-digit code
pasted in from his phone every time.

**Alternative: writing the SQLite DB directly** (used 2026-08-07 to add the
organice monitor). Viable, and simpler than the Socket.IO dance when you just
want one monitor, but it has one trap that makes it silently useless if
missed:

**Kuma loads monitors into memory at startup. An INSERT alone does nothing —
the container must be restarted before the new monitor is ever checked.**
Same class of mistake as the Donetick `sync_version` trap recorded in the
task-management section: editing an app's database behind its back leaves the
app's own state stale.

`sqlite3` is not on the Pi, but it IS inside the container, so everything runs
through `docker exec`. The recipe, all verified:

```sh
DB=/app/data/kuma.db
# 1. Consistent backup FIRST — .backup, not cp: the DB is in WAL mode, so a
#    plain file copy can miss everything sitting in kuma.db-wal.
docker exec uptime-kuma sqlite3 $DB ".backup /app/data/kuma.db.bak-$(date +%Y%m%d-%H%M%S)"
# 2. Insert, naming columns explicitly and letting the rest default. NOTE the
#    column is `maxretries`, not `max_retries`.
docker exec uptime-kuma sqlite3 $DB "INSERT INTO monitor (name, active, user_id, interval, url, type, keyword, ...) VALUES (...);"
# 3. Link notifications — a monitor with no monitor_notification row is
#    monitored but silent, which is worse than not monitoring it.
docker exec uptime-kuma sqlite3 $DB "INSERT INTO monitor_notification (monitor_id, notification_id) VALUES (<new-id>, 1);"
# 4. THE STEP THAT MATTERS
docker restart uptime-kuma
# 5. Verify it actually runs, rather than assuming
docker exec uptime-kuma sqlite3 -header $DB "SELECT status,msg,ping FROM heartbeat WHERE monitor_id=<new-id> ORDER BY id DESC LIMIT 3;"
```
Status `1` = UP, `0` = DOWN, `2` = PENDING. Also worth running
`PRAGMA integrity_check;` after any direct write, and confirming no other
monitor went DOWN across the restart.

Status-page membership is a separate `monitor_group` row, so a monitor
inserted this way is deliberately absent from the public page until one is
added.

One payload gotcha for scripted monitor creation on 2.4.0: `add` requires
`"conditions": []` explicitly or the insert fails a NOT NULL constraint.
The full monitor object returned by `monitorList` also isn't directly
resubmittable to `add` as-is — several of its fields are response-only
decorations, not real `monitor` table columns, and each throws its own
opaque `SQLITE_ERROR: table monitor has no column named X` one at a time
rather than a single combined error: strip `id`, `childrenIDs`, `path`,
`pathName`, `parent`, `forceInactive`, `includeSensitiveData`,
`maintenance`, `screenshot`, `remoteBrowser`, and `tags` (tags live in a
separate join table, added via `notificationIDList`/tag-specific calls
instead, not the `add` payload) before submitting.
A second gotcha, for adding a monitor to a status page's group: `saveStatusPage`
takes `(slug, config, imgDataUrl, publicGroupList)` — `imgDataUrl` must
be `""` not `null`/omitted (a null fails a `.startsWith` call server-
side), and if `config` was fetched from the **public** REST endpoint
(`/api/status-page/:slug`) rather than the authenticated `getStatusPage`
socket event, it's missing `domainNameList` entirely (stripped from the
public response) — round-tripping it back as-is throws an opaque
`"Invalid array"` with no field name in the message; ground-truthed by
reading `/app/server/model/status_page.js` directly inside the running
container (`docker exec uptime-kuma grep -n ...` on the Pi) rather than
guessing further. Fix: explicitly set `config.domainNameList = []` if
missing before saving. `publicGroupList` itself isn't returned by
`getStatusPage` at all (confirmed live — only `config` comes back); fetch
it from the public REST endpoint instead, splice the new monitor
(`{id, name}` is enough) into the right group's `monitorList`, and submit
that alongside the authenticated `config`.

**Switched to `louislam/uptime-kuma:2.4.0-slim-rootless` (2026-07-23)** —
the standard `2.4.0` image carried 64 CRITICAL CVEs, 43 of them in
`chromium-common` (bundled for "real browser" monitors; confirmed live via
the metrics endpoint that none of the 23 monitors here use that type, only
http/keyword/ping/port). The new image cut CRITICAL count to 15 (remaining
ones are base-OS packages, not Chromium). Also runs as uid 1000 ("node")
instead of root — real container hardening on top of the CVE reduction.
`./data` was root-owned from the old image's root process; one-time
`chown -R 1000:1000` on the Pi before the swap, otherwise the rootless
container can't write its own database. Verified live: all 23 monitors +
full heartbeat history survived, status page still serving.

### Podman watchdog (Mac, added 2026-07-26)

**The incident:** the Mac's Podman VM (`krunkit`, libkrun backend) wedged
for roughly two days without anyone noticing — `podman ps` just hung/
timed out, every container looked "gone" from the CLI even though the
VM process was technically still alive. Root-caused via macOS's own
crash-writes diagnostics (`/Library/Logs/DiagnosticReports/krunkit_*.diag`):
34.36 GB written to disk over 12.26 hours (~780 KB/s sustained,
tripping Apple's runaway-write heuristic), with the process's stack
stuck specifically in the VM's virtio block-device worker thread. Not a
sleep/wake issue (this Mac hadn't slept in the relevant window) and not
a disk-space issue (196 GB free throughout). The specific container
responsible for the write volume couldn't be identified after the fact —
none of the app data directories on disk are anywhere near 34 GB, so it
was write *churn* (DB WAL/journal activity, log rotation, or similar)
rather than persisted growth, and the container logs from that window
were lost when the VM had to be force-restarted (`kill -9` the wedged
`krunkit` PID, then `podman machine start`) to recover.

**Why this needed its own monitor, not one of the existing 24:** every
other Uptime Kuma monitor in this stack checks an app *over the
network* from the Pi. This failure was the Mac's own local Podman
socket hanging — invisible from outside, since nothing external could
tell "app down" apart from "Podman itself wedged."

**The fix — a dead-man's-switch, not a poll:** `podman-watchdog/` runs
every 2 minutes via launchd (`uk.mathewcsims.podman-watchdog`,
`StartInterval`, not `StartCalendarInterval`). Each run does one
`podman ps` with a **hard 15s subprocess timeout** — critical, since the
whole point is that `podman ps` can itself hang indefinitely when the VM
is wedged — then pings Uptime Kuma's push-monitor API with `status=up`
(includes the container count) or `status=down` (includes the reason:
timeout, non-zero exit, or exception). The Kuma monitor ("Podman (Mac)",
id 25, 150s interval / 60s retry / 2 retries) fans out through the same
Discord notification channel as every other monitor.

**It now also RESTARTS the VM (added 2026-08-08), because reporting was not
enough.** On 8 August the machine died ~90 seconds after a clean
post-reboot start. Detection worked perfectly — the watchdog caught it 43
seconds in, pinged down, and Kuma escalated to Down Count 5 with Discord
attached. And then every Mac-hosted app stayed down until a human happened
to look, roughly seven minutes later. At 3am that is hours. Detection was
never the missing piece.

> **The root cause of that particular death was found afterwards, and fixed
> separately — see "Why launchd was killing the VM" below.** The watchdog's
> restart is the backstop for VM deaths we cannot name; that fix prevents the
> one we can. Both are worth having, but they are not the same thing, and
> auto-restart should not be mistaken for a cure.

After **2 consecutive** failed probes the watchdog now runs
`podman machine start` itself, guarded three ways:

| Guard | Value | Why |
|---|---|---|
| `FAILURES_BEFORE_RESTART` | 2 | Never act on one failure. At a 120s interval this is 2–4 min of confirmed-dead, deliberately longer than a normal `machine start`. Without it the watchdog fights `podman-autostart.sh` at every boot — it saw exactly such a transient 43s into the last one, while autostart was still mid-start |
| `RESTART_COOLDOWN` | 600s | A VM that dies immediately after starting must not become a restart loop hammering the host |
| `MAX_RESTART_ATTEMPTS` | 3 | If three tries have not fixed it, a restart is not the fix. Stop, alert loudly, leave it. **Per-outage** — reset on the first success, so a later unrelated failure gets a fresh budget |

An `O_EXCL` lock file makes the restart mutually exclusive, since
`podman machine start` takes longer than the 120s scheduling interval and
two overlapping starts is its own failure mode. The lock times out after
`MACHINE_START_TIMEOUT * 2` so a killed run cannot deadlock every future
restart — which would be the same outage in a different costume.

Restart outcomes go to **Apprise**, not Kuma: a push monitor can only move
between up and down, and has no way to say "I restarted your VM", which is
the part actually worth telling someone. A successful restart is still a
**warning**, not an info — it means the VM died, and the restart treats the
symptom rather than the cause.

State (`consecutive_failures`, `restart_attempts`, `last_restart`) lives in
`~/podman-watchdog/state.json`, outside the repo alongside the push token,
because each launchd run is a separate process with no memory of the last.

**A responsive VM with zero containers now counts as DOWN, not up.** The
probe used to report `up` on any `podman ps` that exited 0, including one
returning nothing — so the monitor would go green while every Mac-hosted
app was down. That was survivable while the script only watched; it is not
now that it restarts things unattended, because `podman machine start`
brings the VM back and, if the in-VM `podman-restart.service` does not then
start the containers, that green-monitor-over-dead-stack state is exactly
where you land. For the same reason a successful restart is followed by
`podman start --all --filter should-start-on-boot=true`, mirroring what
`podman-autostart.sh` does rather than trusting the VM to do it.

All eleven behaviours are covered by a sandboxed test — fake `podman`,
stubbed endpoints, temp state dir — verifying that a single failure does
*not* restart, the second does, the cap holds at 3, a success clears both
counters, a failed restart raises a `failure` alert rather than a warning,
cooldown and an existing lock both block, a hung or killed start releases
its lock instead of deadlocking, zero containers reports down, and a
restart starts the containers as well as the VM.

### Why launchd was killing the VM (found and fixed 2026-08-08)

**`autostart/uk.mathewcsims.podman-autostart.plist` was missing
`AbandonProcessGroup`, so launchd was killing the very VM the job exists to
start.** From `launchd.plist(5)`:

> When a job dies, launchd kills any remaining processes with the same
> process group ID as the job. Setting this key to true disables that
> behavior.

That only bites if podman's VM processes stay in the launching process
group. They do — confirmed live:

```
  PID  PPID  PGID   COMM
 3586     1  3581   /opt/podman/bin/gvproxy
 3587     1  3581   /opt/podman/bin/krunkit
```

`PPID 1` because podman itself exited and they were reparented to launchd;
`PGID 3581` is the `podman machine start` invocation's group, which they
never leave. No `setsid`, no detach. Inside a launchd job that group is the
*job's* group, so:

1. the agent runs `podman-autostart.sh`;
2. `podman machine start` spawns `gvproxy` + `krunkit` into the job's group;
3. the script finishes its container listing and exits — **10:56:12**;
4. the job dies, launchd tears down the process group;
5. VM gone — the watchdog saw it dead at **10:57:41**.

Two things this explains that nothing else did. There is **no crash report**
for either process, because they were signalled rather than crashing. And
re-running **the same script by hand** from an interactive shell worked and
stayed up, because the process group belonged to a shell session with no
launchd job to be reaped against. Same script, same command, opposite
outcome — that difference is the diagnosis.

**Not deterministic.** The stack has survived plenty of reboots, so there is
a race between launchd's teardown and podman's children being reparented.
The fix removes the race rather than winning it.

A wrong theory was held first and is recorded so it is not re-derived:
**Podman Desktop was suspected purely because it launches at login at the
same second** the autostart agent runs. There is no mechanism behind that —
its `settings.json` has no machine-autostart preference and nothing shows it
starting or stopping machines. Co-timing was the entire case, which is not
one.

**`reload.sh` now installs the anchor from the repo (2026-08-08).** It used
to only reload `/etc/pf.conf`, so editing `pf-lockdown/<anchor>` in the repo
and running the script applied **nothing** — the file had to be copied to
`/etc/pf.anchors/` by hand as a separate step, which is easy to forget and
impossible to notice, because the reload succeeds and reports success either
way. That is exactly what happened when ports 3600 and 3601 were added for
Fizzy and Super Productivity: both stayed reachable from every device on the
LAN while the repo, the commit and this document all said otherwise. The repo
is now the source of truth, as it already is for the Pi's Caddyfile — so a
hand-edit of the live file will be overwritten on the next run, which is the
intended direction.

**BOTH podman plists need this key, not just the autostart one.** The
watchdog now runs `podman machine start` in its remediation path, so it has
exactly the same exposure — and there it is worse than a plain omission:
without the key the watchdog would start the VM, alert "restarted
automatically", exit, have launchd kill the VM it just started, and repeat
until `MAX_RESTART_ATTEMPTS` was exhausted — burning every attempt while
reporting success each time, and ending with the stack still down. Caught on
review of the commit that added the restart, before it ever ran against a
real outage.

Every other launchd job in this repo was checked and does **not** need it:
`contact-sync`, `kopia-mac-backup`, `kopia-verify`, `kopia-mirror`,
`trivy-scan`, `paperless-task-alert` and `pf-lan-lockdown` all run
synchronously and leave no background process behind. The rule is narrow —
a job needs `AbandonProcessGroup` only if the thing it starts is *meant* to
outlive it.

**The autostart plist is now tracked in the repo**, which it was not before
— only the script was, unlike `podman-watchdog/` which tracked both.
Reinstall either with:

```
cp autostart/uk.mathewcsims.podman-autostart.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u)/uk.mathewcsims.podman-autostart
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/uk.mathewcsims.podman-autostart.plist
launchctl print gui/$(id -u)/uk.mathewcsims.podman-autostart | grep properties
```

That last line must list `abandon process group`. If it does not, the key
did not take and the VM is one boot away from dying again.

**Setup note:** Kuma's plain API key only authenticates read-only
endpoints (see the caveat above) — monitor creation went through the
Socket.IO `add` interface with a live admin 2FA code, same as every
other scripted monitor add. Two undocumented quirks hit along the way,
worth knowing if this is ever redone: (1) the `add` payload needs the
**exact full field set** an existing monitor has (fetched via a
`monitorList` push event, not a request/response call — `getMonitorList`
has no callback in this version) — a partial/guessed payload throws an
opaque `Cannot read properties of undefined (reading 'every')` with no
useful detail; (2) a push monitor's `pushToken` is **not** server-generated
on create — the Kuma frontend normally generates it client-side, so a
scripted `add` leaves it null and needs a follow-up `editMonitor` call
with a random token to actually make the monitor reachable.

**Push token storage — the one secret in this repo NOT in Pass:** lives
at `~/podman-watchdog/push-token` (0600, outside the repo) instead.
Two reasons: it's low-sensitivity (a Kuma push token can only post
up/down pings to one monitor — a leak's worst case is a false status,
not a real security exposure), and more fundamentally, Pass writes
require the user's own interactive session — every automated/launchd
job in this repo authenticates as a Pass "agent" PAT, which is
**read-only by design** (see the agent access model above), so a script
creating a monitor programmatically has no durable way to write the
resulting token back into Pass without a human in the loop regardless.
Same tradeoff already made for contact-sync's MS Graph refresh-token
cache.

---

## Vikunja webhook relay (https://vikunja-relay.mathewcsims.uk) — DECOMMISSIONED

> **DECOMMISSIONED 2026-08-08**, with Vikunja itself — it existed only to
> carry Vikunja's webhooks, so it had nothing left to relay. Container,
> image, Caddy site block, DNS records and `~/vikunja-webhook-relay` on the
> Pi are all gone. Kept below because the *pattern* is the reusable part:
> `wanderer/memo-relay/` and `tailscale-webhook-relay/` are the same shape,
> and the payload-mismatch problem it solves recurs every time an app's
> webhook meets Apprise's `/notify`.

A small purpose-built bridge, not a third-party app: Vikunja's own webhook
feature (Settings → Webhook Notifications) POSTs its own JSON shape
(`{event_name, time, data}`) to a target URL when task events fire; the
Apprise container's `/notify` endpoint (see above) requires a `{title,
body}` shape instead. Confirmed directly against the live Apprise
container: posting a Vikunja-shaped payload gets back
`{"error": "Payload lacks minimum requirements"}` (400) — the two don't
line up on their own, and Vikunja has no native Discord/Apprise
notification provider of its own (unlike Uptime Kuma) to fall back on
either. `vikunja-webhook-relay/relay.py` sits in between: verifies
Vikunja's `X-Vikunja-Signature` (HMAC-SHA256 of the raw body, per
[Vikunja's webhook docs](https://vikunja.io/docs/webhooks/)), pulls the
task title out of `task.overdue`/`task.reminder.fired`/`tasks.overdue`
events, and forwards a proper `{title, body}` to the Apprise container by
container name over `pi-shared`.

**Own code, not a pulled image** — `vikunja-webhook-relay/Dockerfile`
builds from `python:3.13-alpine`, pinned by tag and digest, running
`relay.py` (stdlib only, no extra pip dependencies to track for CVEs).

**Real access control is HMAC verification inside the relay itself**, not
the LAN-gate — `WEBHOOK_SECRET` must match exactly what's entered in
Vikunja's own "Secret" field, and every request is rejected with 401
unless the signature checks out. The LAN-gate on
`vikunja-relay.mathewcsims.uk` (same `remote_ip private_ranges` + `abort`
pattern as Apprise/Speedtest Tracker) is defense in depth on top of that,
for consistency with every other machine-to-machine app in this repo.

**To bring it up on a fresh machine:**
1. Generate the secret and create its Pass item — run this yourself, under
   your own personal `pass-cli` session (agent tokens are read-only, can't
   create items):
   ```
   ./scripts/pass-create-vikunja-relay-secret.sh
   ```
   It prints the generated secret once at the end — copy it for step 4.
2. **Pi:** copy the `vikunja-webhook-relay/` folder over (`scp -r`), then
   deploy with secrets fetched live from Pass:
   ```
   ./scripts/pass-deploy-remote.sh vikunja-webhook-relay mathew@babel '~/vikunja-webhook-relay'
   ```
   Quote the tilde — an unquoted `~/vikunja-webhook-relay` expands on the
   Mac (this machine), not the Pi, before it ever reaches `ssh`. First
   deploy auto-builds the image since none exists yet on the Pi; after
   editing `relay.py`/`Dockerfile`, redeploy with
   `docker compose up -d --build` explicitly instead — this project uses
   `build:`, not a pulled `image:`, so a plain `up -d` won't pick up code
   changes to an image that already exists.
3. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
4. **DNS:** its own explicit `A` record for `vikunja-relay.mathewcsims.uk`,
   plus a NextDNS rewrite → `10.0.1.19` (same as every other
   LAN-only app, since Caddy's LAN-gate needs the request to actually
   arrive from a private IP).
5. In Vikunja itself (Settings → Webhook Notifications): **Target URL** =
   `https://vikunja-relay.mathewcsims.uk/webhook`, **Secret** = the value
   from step 1, then tick whichever events you want notifications for.
6. Test end-to-end with a correctly-signed request (this is how the
   initial deploy was verified — computes the HMAC using the real secret,
   fetched from Pass, entirely in-memory, never printed):
   ```sh
   pass-cli item view --vault-name "Self-Hosted Secrets" --item-title "VikunjaWebhookRelay" --output json \
       | python3 -c '
   import json, sys, hmac, hashlib, subprocess
   d = json.load(sys.stdin)
   secret = None
   for s in d["item"]["content"]["content"]["Custom"]["sections"]:
       for f in s["section_fields"]:
           if f["name"] == "WEBHOOK_SECRET":
               secret = list(f["content"].values())[0]
   body = b"""{"event_name":"task.overdue","time":"2026-07-05T12:00:00Z","data":{"task":{"title":"Test"}}}"""
   sig = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
   subprocess.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}\n",
       "-X", "POST", "https://vikunja-relay.mathewcsims.uk/webhook",
       "-H", f"X-Vikunja-Signature: {sig}", "--data-binary", body])
   '
   ```
   A `200` here, followed by "Sent Discord notification" in
   `docker logs apprise` on the Pi, confirms the full chain end-to-end.

### Reminders not reliably reaching Discord (investigated, root cause found)

Symptom: Discord notifications for `task.reminder.fired` were unreliable,
worse for recurring tasks. **Not a relay or Apprise problem** — the relay's
own logic and the delivery chain were confirmed correct; the reminders
themselves were being silently deleted from Vikunja before the reminder
cron ever had anything to fire.

**Confirmed via direct inspection of `vikunja/db/vikunja.db`:** of 5 active
recurring tasks, 2 had zero rows in `task_reminders` despite having a real
due date days away — the reminder cron (`pkg/models/task_reminder.go`,
`getTasksWithRemindersDueAndTheirUsers`) only ever looks at that table, so
there was nothing to find, dispatch, or deliver for those two tasks. The
other 3 recurring tasks still had theirs (why some survive and some don't
is exactly the "unreliable" part).

**Root cause: a documented, maintainer-acknowledged Vikunja API design
limitation**, not a bug we can patch (pinned image, not built from
source) — [go-vikunja/vikunja#1459](https://github.com/go-vikunja/vikunja/issues/1459),
closed `not planned`. Go's JSON decoder can't distinguish "field omitted
from the request" from "field explicitly set to its zero value," so
Vikunja's task-update endpoint does a **full replace**, not a partial
merge — sending `{"done": true}` to check a task off silently clears
`reminders` (and description, priority, assignees, and others) back to
empty unless the client re-sends the complete task object every time.
Confirmed the server's own recurrence-handling logic
(`setTaskDatesDefault`/`setTaskDatesMonthRepeat`/
`setTaskDatesFromCurrentDateRepeat` in `pkg/models/tasks.go`) *does*
correctly shift reminders forward when a repeating task completes via the
normal "mark done" flow — so the loss happens on whichever client
interaction sends a thinner payload than that.

**Investigated but not conclusively pinned down which client action
triggers it.** Ruled out: CalDAV/Shortcuts (not in use — web UI and the
official mobile app only, confirmed with the user). Traced the mobile
app's own source (`go-vikunja/app`, a separate Flutter codebase from the
web frontend, not just a wrapped PWA): its "swipe/tap to complete" path
(`task_page_controller.dart`'s `markAsDone`) mutates the already-loaded
`Task` object and round-trips it through `TaskDto.toJSON()`, which *does*
correctly serialize `reminders` — so the common completion gesture looks
clean on inspection. **Separate, smaller bug found along the way**: that
same `toJSON()` never includes `repeat_mode` at all, so any update from
the mobile app would silently reset a task using month- or
from-current-date-repeat back to default repeat mode — not currently
biting us (all active tasks already use default mode) but worth knowing
if that ever changes.

**Fix applied now**, while the exact trigger stays an open question:
re-set all 6 active tasks (the 5 recurring ones explicitly with
`relative_to: due_date, relative_period: 0` — the same self-correcting
form already working for the 3 that hadn't lost theirs, so it survives
future recurrences rather than needing to be redone) via a **full-object
GET-then-PUT** through the raw API (token from the `vikunja` MCP server's
own config, `claude_desktop_config.json` — read into a variable, never
retyped literally), verified against the DB afterward to confirm no other
field (`due_date`, `repeat_after`, `priority`, `project_id`) was
disturbed by the round-trip.

**Added real observability for next time**: `vikunja-webhook-relay/relay.py`
had zero logging at all before this (the handler explicitly silences
`BaseHTTPRequestHandler`'s default access log, and nothing else printed
anything) — genuinely no way to tell whether Vikunja had even attempted a
webhook delivery versus the relay dropping it versus Apprise rejecting it.
Now logs, one line each: signature-rejected/bad-JSON requests, every
accepted event's `event_name`, and the Apprise forward's outcome
(status code or the exception). Redeployed via the same
Pass-secret-sourced `docker compose up -d --build` pattern as any other
change to this app (never a bare `up -d` — see the standing rule
elsewhere in this doc); verified end-to-end with the signed test request
above, confirmed lines actually appear in `docker logs
vikunja-webhook-relay`.

**If this recurs**: check `docker logs vikunja-webhook-relay` first (now
meaningful) to see whether Vikunja even sent the event; if it did, the
relay/Apprise chain is proven fine and the question is purely "why did
this task's reminder row disappear" — check `task_reminders` directly via
`podman run --rm -v vikunja/db:/db:ro alpine sh -c "apk add --no-cache
sqlite && sqlite3 /db/vikunja.db 'SELECT * FROM task_reminders'"` and
compare against which client/action most recently touched that task.

---

## Tailscale webhook relay (https://tailscale-relay.mathewcsims.uk) — runs on the Pi

Bridges the same kind of schema mismatch as the Vikunja webhook relay,
this time for [Tailscale's webhook feature](https://tailscale.com/kb/1213/webhooks):
Tailscale POSTs a JSON array of `{type, message, data}` events, signed via
a `Tailscale-Webhook-Signature: t=<epoch>,v1=<hmac-sha256 hex>` header
(signing string is `"<epoch>.<raw body>"`); Apprise's `/notify` endpoint
wants a flat `{title, body}` shape.

**Deliberately PUBLIC, not LAN-gated** — the one relay in this repo where
that's correct rather than a gap: Tailscale's own cloud infrastructure
sends these from outside the tailnet entirely, so a LAN/CGNAT gate would
block the real sender. HMAC signature verification inside the relay is
the actual access control (same reasoning as ntfy's auth-default-deny).
Includes a 5-minute clock-skew replay check on the timestamp (Tailscale's
docs don't specify a tolerance; matches the common Stripe-style
convention this signing scheme otherwise mirrors).

**Subscribed to 17 event types** — everything non-deprecated except the
two `node*Authorized`/`node*NeedsAuthorization` aliases: node/user
lifecycle (created/approved/deleted/needs-approval), key expiry
(`nodeKeyExpired`, `nodeKeyExpiringInOneDay`), `policyUpdate` (fires on
every ACL change — a real security-relevant signal: if the ACL is ever
modified by anything other than a deliberate action here, this is how
you'd find out), exit-node/subnet-router misconfiguration warnings, and
the webhook's own tamper-evidence events (`webhookUpdated`/
`webhookDeleted` — notified before whatever changed them could also
silence them, since the notify path doesn't depend on the webhook
surviving).

**Webhook created via the API, not the admin console** — `POST
/tailnet/-/webhooks` returns the signing secret exactly once in the
response; it can't be retrieved again afterward, only rotated (delete +
recreate the webhook, which mints a new secret). Stored in the
"Tailscale Webhook Relay" Pass item — a separate item from the main
"Tailscale" one (which holds the API key itself), same one-secret-per-
concern pattern as everywhere else in this repo.

**Verified live end-to-end**: sent Tailscale's own test-delivery
(`POST /webhooks/{id}/test`) — confirmed the relay received it, validated
the real signature, and forwarded successfully to both Discord and ntfy.
An unsigned request to the same endpoint was independently confirmed
rejected with 401.

---

## Trivy vulnerability scanning (Mac, launchd, weekly)

Closes a real gap: every CVE/version check in this repo up to 2026-07-23
was a one-off manual review during a session like this one — nothing
watched for newly-disclosed CVEs on already-pinned digests in between.
`trivy-scan/scan.py` (launchd job `uk.mathewcsims.trivy-scan`, Sundays
04:00) now does that continuously.

**How it works**: derives the full image list live from every `image:` in
every `compose.yaml` and `FROM` in every `Dockerfile` in the repo — not a
maintained list that could drift from what's actually pinned. Runs
`trivy image --severity HIGH,CRITICAL` against each. State (which CVE IDs
have already been seen, keyed by **repository + tag** — see the 2026-08-02
subsection below for why not the full reference, and why not the bare
repository either) lives outside the repo at
`~/trivy-scan-state/state.json`, same tracked-script/untracked-data split
as `contact-sync/`. Only **newly-seen** CVEs trigger a notification — a
CVE already known and accepted doesn't re-alert every week.

**Real bug found and fixed before this went live**: the first run
produced 1433 findings in one message and the Discord leg of the Apprise
fan-out failed outright (`400 Unsupported Parameters` — confirmed live,
Discord's own embed-description limit, ~4096 chars). ntfy delivered fine;
Discord silently didn't, and Apprise's `424` response was it honestly
reporting a partial failure. Fixed by always sending a short per-image
summary (counts by severity) to the notification, with the full per-CVE
detail written to `~/trivy-scan-state/latest-report.md` for local review
instead of trying to cram it into a chat message.

**Second bug found and fixed**: the first real run also picked up 38
images instead of the real ~24 — a stale `.claude/worktrees/` checkout
from a past agent session (`isolation: "worktree"`) had pre-digest-pin
copies of several compose files lying around, never cleaned up. Excluded
`.claude/` and `.git/` from the image-discovery glob so only what's
actually deployed gets scanned. (The stale worktree itself is still on
disk — worktree removal is a destructive-classifier-blocked action, left
for manual cleanup: `git worktree remove .claude/worktrees/<name>`.)

**What the first clean baseline scan immediately found**: CVE-2026-39087
in ntfy and 64 CRITICAL CVEs in the standard Uptime Kuma image, 43 of them
in its unused bundled Chromium — both acted on same day (see the ntfy and
Uptime Kuma sections above).

**Why raw CVE counts across container images are mostly noise, and what
that means for how findings get presented** (Mathew asked directly
whether 1433 findings in one baseline run was actually useful — worth
recording the answer, not just the fix): a pinned image bundles dozens of
OS packages that accumulate CVEs since it was last rebuilt; "CRITICAL"
severity assumes the vulnerable code path is reachable, which it often
isn't (the Kuma Chromium CVEs are the clearest example — real CVEs, ~zero
actual risk here since no monitor uses that code path). So findings are
now grouped by what they actually call for, not just severity:

- **Fixable** (any severity, a newer image version exists) — summarized
  **per image**, not per CVE. A single pin bump clears everything on that
  image at once, so that's the real unit of action; enumerating each CVE
  individually produced 420 lines in one run for no benefit and blew
  through Discord's size limit. The single worst CVE per image is still
  named as a concrete anchor.
- **Unfixed CRITICAL** (no patch exists upstream yet) — listed
  **individually**, in its own dedicated notification sent separately
  from the fixable summary. Deliberately not filtered out or downgraded:
  no available patch doesn't mean nothing can be done — a short-term
  mitigation (disable a feature, restrict network access, etc.) may still
  be the right call, and that decision needs the specific CVE, not a
  count. Found a real ordering bug building this: with everything in one
  message, the (often much larger) fixable summary ate the whole
  character budget first and silently truncated away 28 of 38 critical
  entries — exactly backwards for what's supposed to be the
  highest-priority bucket. Splitting it into its own message, sent first,
  with shortened lines (CVE ID + package, title dropped — still in the
  full report) fixed it: verified live, all 38 fit with room to spare.
- **Unfixed HIGH** (no patch, lower urgency) — compressed to a per-image
  count in the notification; nothing actionable right now, but still kept
  in full in `latest-report.md` for reference.

Nothing is ever hidden entirely — every CVE from every scan is in
`latest-report.md` regardless of bucket. The buckets only change what the
notification emphasizes.

**First resolution pass (2026-07-23)**: worked through the 420 fixable
findings from the baseline. Two images got a free win just from re-pulling
the same tag (`mysql:8.4.10`, `turboot/nimbus:latest` — same version,
freshly rebuilt digest with patched OS packages). Three got real version
bumps: `ghcr.io/go-vikunja/vikunja` 2.3.0 → 2.4.0, `codeberg.org/forgejo/
forgejo` 16.0.0 → 16.0.1, `getmeili/meilisearch` v1.49.0 → v1.50.0 (inside
`karakeep/compose.yaml`). The other 18 images with fixable findings were
already confirmed on their latest available upstream release/tag — their
fixable CVEs are OS-base-package fixes not yet incorporated into a new
upstream build; nothing to do until upstream rebuilds, not a gap on this
end.

Measured impact, re-scanned before/after: 420 → 381 fixable (-39), image
count with any fixable findings 23 → 21. Precise per-image accounting for
the five touched images: Vikunja fully cleared (26→0), Meilisearch fully
cleared (1→0), mysql partially (22→19), nimbus partially (16→7), Forgejo
unchanged (1→1, a gRPC xDS/RBAC dependency issue — Forgejo, a git host,
never exercises that code path, so like Kuma's Chromium this is present
but not actually reachable; will clear whenever Forgejo's own go.mod
bumps grpc upstream). A version bump doesn't necessarily change the base
OS layer underneath, which is why several only partially cleared rather
than dropping to zero.

**Real incident during this pass, handled correctly**: bumping
Meilisearch to v1.50.0 crash-looped it — v1.50 refuses to start against a
v1.49-written database without an explicit migration
(`Error: Your database version (1.49.0) is incompatible with your current
engine version (1.50.0)`), taking Karakeep's search down. Fixed properly:
backed up `karakeep/meilisearch-data/` first (17MB, trivial), then ran a
one-off `meilisearch --experimental-dumpless-upgrade` against the same
volume outside compose to perform the in-place migration (Meilisearch's
own docs flag this as experimental and warn it can leave an instance
unrecoverable if interrupted — hence the backup first). The migration
step itself completed and persisted (`VERSION` file read `1.50.0`
immediately after) even though the *following* serve-forever phase got
killed by a tool timeout; restarted normally via `pass-deploy.sh` and
confirmed genuinely healthy — clean startup, no crash loop, Karakeep's
`/api/health` and the app itself both verified live afterward.

### State is keyed by repository + tag, not the full reference (2026-08-02)

**The bug this fixes.** State used to be keyed by the *full* image
reference, digest included. Every pin bump therefore created a brand-new key
with no history, and that image's entire existing finding set re-reported as
"new". A CVE pass is precisely the thing that bumps digests — so **fixing
CVEs guaranteed a false alarm on the next scan.** Seen live: the 2026-08-02
pass eliminated 25 findings and introduced none, and the very next run
reported **"155 new findings"** across the four re-pinned images. Nothing had
regressed; the scanner had simply lost their history.

**Why not key on the bare repository.** That was the obvious fix, was tried
first, and is wrong. This repo pins several *distinct* images from a single
repository:

| | |
|---|---|
| `caddy:2.11.4-alpine` | vs `caddy:2.11.4-builder-alpine` |
| `python:3.13-alpine` | vs `python:3.14-slim` |
| `getmeili/meilisearch:v1.36.0` (wanderer) | vs `:v1.50.0` (karakeep) |

Collapsing those means whichever scans last overwrites the others, so their
findings vanish from state and re-alert on the next run — **alternating
forever, which is worse than the bug being fixed.**

**So: repository + tag, dropping only the digest** (`repo_key()`). Verified
after the change: 37 images, 37 distinct keys, no collisions. All five of
the 2026-08-02 re-pins now map to a stable key.

Consequence worth knowing: bumping a version *tag* (uptime-kuma 2.4.0 →
2.5.0) still creates a new key and re-reports. That is defensible — a
different upstream version deserves re-review — and it is not what caused
the false alarm, which was digest churn on unchanged tags.

**Three related behaviours added at the same time:**

- **Re-pins are surfaced, not hidden.** The digest is recorded as `ref`, and
  a change is reported as *"N image(s) re-pinned, clearing N finding(s)"* in
  the notification and per-image in the report. A rebuild reads as "same
  findings, new build" rather than silence.
- **Old state migrates on load**, unioning the history of keys that collapse
  together — deliberate, since those CVE IDs have all been seen and reported
  already, and the state file exists to stop them re-alerting.
- **Stale keys are pruned** when an image is no longer pinned anywhere in the
  repo. Guarded on an error-free run: if any image failed to scan its key
  would look absent, and pruning would silently discard real history, so a
  transient registry error must never cost the suppression list. This
  immediately removed a genuine orphan — `ghcr.io/mbombeck/healthlog:latest`,
  left behind when that image went from `:latest` to a digest pin.

Verified against the live state file: 46 keys migrated to 38, the orphan
pruned, and two consecutive full runs both reporting **no new findings**.

### Confirmed baseline (2026-08-02, after that day's CVE + hardening passes)

**809 HIGH/CRITICAL across 37 images** — 537 fixable-upstream, 65 unfixed
CRITICAL, 207 unfixed HIGH. Remember what "fixable" means here: *a patched
version exists somewhere upstream*, *not* that it can be fixed from this
repo. Nearly all of these need the image maintainer to rebuild.

**Eleven images carry zero HIGH/CRITICAL findings**, including all three
patched that day: `codeberg.org/forgejo/forgejo`,
`lscr.io/linuxserver/bookstack`, `lscr.io/linuxserver/speedtest-tracker`,
plus `ghcr.io/go-vikunja/vikunja`, `copyparty/ac`, `ghcr.io/sintan1729/
chhoto-url`, `ghcr.io/mbombeck/healthlog`, `nginx:1.31.3-alpine`,
`python:3.13-alpine`, `getmeili/meilisearch:v1.50.0` and
`getmeili/meilisearch` in karakeep.

Where the volume actually sits — all accounted for above under *Unfixed
CVEs: what is left, and why the mitigations are sufficient*:

| Image | Total | Fixable | uCRIT | uHIGH | Exposure |
|---|---|---|---|---|---|
| karakeep | 127 | 48 | 11 | 68 | public, mitigated, reachability documented |
| uptime-kuma | 108 | 73 | 6 | 29 | public; gnutls CRITICALs verified unreachable |
| immich postgres | 86 | 70 | 7 | 9 | LAN/tailnet-only |
| immich-server | 67 | 23 | 8 | 36 | LAN/tailnet-only |
| immich-machine-learning | 49 | 23 | 8 | 18 | LAN/tailnet-only |
| kopia | 37 | 37 | 0 | 0 | LAN/tailnet-only |
| ghost | 37 | 23 | 6 | 8 | public |
| timetagger | 30 | 16 | 6 | 8 | public, behind oauth2-proxy |
| apprise | 29 | 9 | 5 | 15 | LAN/tailnet-only; the 5 CRIT are really 4 distinct Perl CVEs + 1 OpenSSH |

Use this table as the comparison point for the next scan, since the
notification only ever reports the *delta*.

---

## Kopia backups (https://backup.mathewcsims.uk) — server on the Pi, LAN-only

[Kopia](https://kopia.io) backs up every app's own data across all three
hosts to Backblaze B2. Client-side encryption
is on by default (not optional, unlike rclone which needs `crypt` bolted on),
snapshots are content-defined-chunked so repeat backups only upload what
changed, and scheduling is automatic.

### Database dumps run BEFORE every snapshot (added 2026-07-30)

**The problem this fixes.** Until this was added, every database in this
repo was "backed up" by snapshotting its **live data directory while the
service was running** — `healthlog/pgdata`, `blog/db`, `bookstack/db`,
`nimbus/db`, plus a dozen SQLite files, most in WAL mode. That is not a
backup. A file-level copy of a running Postgres or MySQL datadir can
capture torn pages and a partially-written WAL; a WAL-mode SQLite copy can
capture a `.db` and `-wal` that disagree. There was no `pg_dump`,
`mysqldump` or equivalent anywhere in the repo. The failure mode is the
nasty one: it looks like a valid backup right up until you need it.

Immich was the only exception, because it ships its own dump — and
restore-testing *that* is what surfaced the gap for everything else.

**What happens now.** Two scripts write consistent, restorable dumps
immediately before their host's snapshots:

| Host | Script | Trigger |
|------|--------|---------|
| Mac | `scripts/dump-databases.sh` | called at the top of `kopia-mac/backup.sh` (02:00) |
| Pi | `pi-db-dumps/dump-databases.sh` | `db-dumps.timer`, a systemd **user** unit, 01:30 |

Both write to a gitignored `db-dumps/` (keeping the last 7 per database;
Kopia keeps the real history), and both alert via **Apprise on failure** —
a dump that fails silently is the whole problem restated.

**`db-dumps/decommissioned/` is exempt from that rotation, deliberately.**
When an app is torn down (see the decommissioned sections above), its final
dump and a cold `tar.gz` of its whole data directory go in there rather than
at the top level. Two reasons. First, rotation only globs
`db-dumps/<label>-*.gz` — it never descends into a subdirectory, so nothing
in there is ever pruned. Second, a torn-down app's *source* directory stops
being snapshotted, and Kopia's retention is counted per source, so relying
on the old snapshots alone means trusting a dormant source's history;
`db-dumps/` is itself a live Kopia source, so an archive parked there is
re-included in every future backup indefinitely. Set the dead source's
policy to `--manual` at the same time, or the scheduler keeps trying to
snapshot a path that no longer exists.

**Per-engine method, and why:**
- **Postgres** — `pg_dump` run *inside* the container, so no credential
  ever reaches the host or a command line (local socket auth is trusted
  there).
- **MySQL / MariaDB** — `--single-transaction` for InnoDB consistency
  without locking the app out; the root password comes from the
  container's own environment via `MYSQL_PWD`, so it never appears in
  argv.
- **SQLite** — `VACUUM INTO` on the Mac, and Python's
  `sqlite3.Connection.backup()` on the Pi (where `sqlite3` isn't installed
  and adding it needs root). Both are the *supported* online-copy APIs and
  are safe against a live WAL database; `cp` is not.

**Incident, 2026-07-30 — the SQLite dump broke Forgejo.** The first version
of the Mac script opened each SQLite source with a plain path
(`sqlite3 "$src" "VACUUM INTO ..."`). The `sqlite3` CLI opens **read-write**
by default, which takes write locks, checkpoints the WAL and rewrites the
`-shm` of a database another process already has open. About 20 minutes
later Forgejo began failing every query with `file is not a database` and
serving HTTP 500 — while the file itself was completely valid
(`integrity_check` ok, row counts matching the dump exactly). It was the
running application's *connection state* that broke, not the data; a
container restart cleared it.

The fix is one URI parameter: open the source `file:$src?mode=ro`. A
read-only handle takes no write lock and cannot checkpoint, so the running
app is untouched — verified by confirming the source file's mtime is
identical before and after a dump run. The Pi script always did this
correctly (Python's read-only URI); the two are now consistent. **Do not
remove `mode=ro`** — it is the difference between a backup and an outage.

**Incident, 2026-07-31 — the first unattended run lost three dumps to a
`PATH`.** The morning after the dump work went in, the Mac's 02:00 run
reported failures for exactly the three container-based dumps (healthlog
Postgres, Ghost MySQL, BookStack MariaDB) while all eight SQLite dumps
succeeded. Nothing was wrong with the databases — every command worked
perfectly when re-run by hand minutes later.

The cause was the LaunchAgent's `PATH`. **launchd gives a job a minimal
environment, not your login shell's**, and Podman Desktop installs its CLI
to `/opt/podman/bin`, which is on no default `PATH` anywhere. Under
launchd, `podman` simply did not exist. The SQLite dumps were unaffected
only because macOS ships `sqlite3` in `/usr/bin` — and that asymmetry is
what made the failure look like a database problem rather than an
environment one. Interactive testing could never have caught it, because
an interactive shell already has `/opt/podman/bin`.

Two changes, because there were two faults:

1. `/opt/podman/bin` prepended to the plist's `PATH`. **Anything a
   launchd/systemd job invokes must be on that job's own `PATH`** — check
   with `command -v` in the job's environment, not in your terminal.
2. The script now tests the *dump command's* exit status. It previously
   ran `podman exec … | gzip > file` inside an `if`, and in a pipeline
   `if` tests the **last** command — gzip, which cheerfully exits 0 after
   compressing nothing. A missing binary therefore read as success, and
   the only thing that noticed was the "suspiciously small" size guard.
   Dumps now write to a temp file first so the producer's own status is
   what gets checked, with an explicit up-front `command -v podman`
   preflight so a missing runtime is one clear message instead of three
   mystery failures. The size guard stays as a second line of defence.

**The safety net worked, and that is the point.** The size guard caught
the empty dumps, the script exited non-zero, and Apprise alerted — which is
how the problem was known about at all. But a guard catching what error
handling should have caught is a warning, not a success: verify both the
success *and* failure paths of any scheduled job (`env PATH=/usr/bin:/bin
sh scripts/dump-databases.sh` reproduces this one exactly).

**Deliberately not dumped:** copyparty's `up2k.db`/`shares.db`/
`sessions.db` (regenerable dedup index and session state — its actual
files are backed up), karakeep's `queue.db` (transient job queue),
wanderer's `pb_data/auxiliary.db` (PocketBase's 35 MB log database; the
real `data.db` IS dumped), and `msims-link/data/backups/*` (chhoto-url's
own rotating backups of the database we already dump properly).

**Pi wrinkle worth knowing:** the Pi's Kopia is a *server* with its own
internal scheduler, so there's no host-side "before snapshot" hook like
the Mac's `backup.sh`. Worse, `kopia-server/entrypoint.sh`'s source-config
loop only runs on the very first bootstrap against an empty repository —
so simply adding a new mount would be **silently ignored forever**. The Pi
dump script therefore runs `kopia snapshot create /data/db-dumps` itself
at the end.

**Restore-tested, not assumed** — every engine, into a throwaway target,
with the live database verified unchanged afterwards:

| Engine | Result |
|---|---|
| Postgres (healthlog) | 117 tables, 0 errors |
| Postgres (nimbus, Pi) | 12 tables, 0 errors |
| MySQL (ghost) | 92 tables, 6 posts; live unchanged |
| MariaDB (bookstackapp) | users 2=2, settings 34=34, roles 4=4 vs live |
| SQLite (owl/forgejo/vikunja) | `integrity_check` ok; 12/131/38 tables |
| SQLite (uptime-kuma, Pi) | ok; 30 tables, 40,035 heartbeat rows |

**A dangerous trap, hit while building this.** The MySQL dump originally
used `--all-databases`. Such a dump embeds `USE <db>;` and
`CREATE DATABASE` statements that **override whatever target you restore
into** — so piping it into a scratch database silently restored over the
*live* Ghost and `mysql` system databases instead. No data was lost (the
dump was minutes old and identical), but it easily could have been. The
script now dumps each app's own database **without** `--databases`, which
produces portable output that restores into any target. If you ever change
this, keep that property — it's what makes a restore test safe to run at
all. Trade-off accepted: users/grants are no longer captured, but they're
reproducible from Pass and the compose files, and aren't app data.

**Post-dump health check.** Both scripts now verify, immediately after
dumping, that every app whose database they touched is still serving —
checked via the public hostname (the path that actually matters, and no
port list to drift). 2xx/3xx/4xx all count as healthy, since 401/403 are
auth gates working and 30x are normal redirects; only **5xx or no response**
is treated as broken, which is exactly how the incident above presented. A
failure fires an Apprise alert naming the affected hosts and makes the
script exit non-zero.

This exists because the incident was caught by Mathew hitting an error
page, not by any automation: the script checked only that *its own* work
succeeded, and cheerfully reported success while the apps it had just
touched were returning HTTP 500.

Worth knowing if you edit that block — its two failure paths each had a bug
that only a deliberate failure test caught. `curl -w '%{http_code}'` already
prints `000` on a connection failure, so an extra `|| echo 000` produced
`000000`, which matched neither `5*` nor `000` and silently passed. And
because `set -e` is on, curl's non-zero exit on an unreachable host killed
the script before it could report, so the guard is `|| true` — which keeps
curl's own `000` while neutralising the exit status. **Test the failure
path, not just the happy path**, if you change it.

**Still to do (phase 2):** once these dumps have a few weeks of history,
drop the raw datadir paths (`healthlog/pgdata`, `blog/db`,
`bookstack/db`, and the SQLite files) from the snapshot sources. They're
the larger B2 cost and, being un-quiesced copies, actively misleading —
but they're worth keeping as a belt-and-braces overlap until the dumps
have proven themselves in anger.

**Architecture — two independent Kopia instances sharing one B2 repository:**
- **`kopia-server/` (Pi, always-on)** — runs `kopia server start` in a
  container, connected DIRECTLY to B2 (not proxying anyone). Backs up the
  Pi's own app data on a daily schedule, hosts the web UI at
  `backup.mathewcsims.uk` (LAN-gated, same pattern as Apprise/Speedtest
  Tracker), and is the designated maintenance owner (garbage collection) for
  the whole shared repository.
- **`kopia-mac/` (Mac, no persistent daemon)** — connects to the SAME B2
  repository directly, but has no long-running process. A launchd job
  (`uk.mathewcsims.kopia-mac-backup`, matching the `autostart/` pattern)
  triggers `kopia snapshot create` daily. A second launchd job
  (`uk.mathewcsims.kopia-verify`, 06:00) verifies the night's backups
  across ALL THREE hosts afterwards and sends the success notification —
  see "Nightly verification" below.

Both instances writing directly to the same repository is safe — Kopia
designates one `user@hostname` as maintenance owner automatically (the Pi,
since it's always on; the Mac only runs on a schedule, so it's the wrong
host to own garbage collection). The web UI shows snapshots from **both**
hosts, since Kopia stores snapshot manifests in the repository itself, not
per-server — connect any client to the shared repo and it sees everyone's
history.

### Nightly verification, and why failure-only alerting wasn't enough

**Added 2026-08-04, after two silent failures.**

Until this, every backup job alerted only when *it* believed it had broken.
That misses the two failure modes that actually happened here, both of
which are silent by construction:

1. **The job that never ran.** The Mac's 2026-08-03 02:00 run wedged on the
   NAS source (below) and never exited. launchd will not start a job whose
   previous instance is still alive, so **the next night's backup never
   started at all**. Nothing alerted, because nothing had failed — the job
   simply had not been allowed to run. It was found by hand, 40 hours later.
2. **The snapshot that "succeeded".** That same NAS source had been
   completing with `errors:30`, capturing 44 MB of a 16 TB source, while
   `kopia snapshot create` exited 0 throughout. Partial success is
   indistinguishable from success to the caller.

`kopia-mac/verify-backups.sh` (launchd, 06:00) exists to catch both. It
ignores what the jobs claim and interrogates the repository — all three
hosts write into one B2 repository, so a single verifier on the Mac sees
every source on every host. Four checks, in order:

| Check | Catches |
|-------|---------|
| **Freshness** — every active source has a complete snapshot < 30h old | the silently skipped night |
| **Cleanliness** — that snapshot has zero errors and zero failed entries | the partial success |
| **Structure** — `kopia snapshot verify --max-errors=0` over those snapshots | missing/corrupt blobs and index entries |
| **Content** (Sundays) — `--verify-files-percent=2`, re-downloading real files from B2 | data that is referenced but no longer readable |

Only when all of them pass does the nightly ✅ notification go out, via the
same Apprise endpoint as everything else (which fans out to ntfy and
Discord). **A green message means the data was verified tonight, not that a
script finished.** Any failure sends a specific 🚨 instead, and the four
cases are worded distinctly — "a source is stale" points at that host's
timer, "structure failed" points at the repository, and they should not be
confused with each other.

**Which sources count as "active" is derived, never hardcoded.** A source is
active unless its Kopia policy sets `scheduling.manual` — precisely the flag
set when an app is decommissioned. So retired apps drop out of verification
automatically while keeping their snapshots, and a newly added source is
picked up with no edit to the verifier. A hardcoded list would rot on the
first app added or removed, which for a backup checker is the failure mode
that matters most.

**Gotcha, found by testing this against the real repository rather than
assuming it worked:** incomplete snapshots must be excluded explicitly.
Kopia checkpoints long-running snapshots periodically and marks interrupted
ones, via an `incomplete` field (`"checkpoint"`, `"canceled"`). These are
real manifest entries with recent timestamps and `errorCount: 0`. The first
version of the freshness check treated the newest of them as the latest
snapshot — and so reported the wedged NAS source, which had not completed
since 2026-08-01, as verified for tonight. That is exactly the
partial-success-looks-like-success bug the script exists to catch,
reproduced inside the checker itself.

To exercise the weekly deep path on demand instead of waiting for a Sunday:

```sh
DEEP_VERIFY_DOW=$(date +%u) VERIFY_FILES_PERCENT=1 ./kopia-mac/verify-backups.sh
```

At 1% that re-downloaded 117 files / 0.9 GB in ~73s, so the configured 2%
is roughly 1.8 GB of B2 egress per week — comfortably inside B2's free
allowance (3x stored bytes per month) for a ~36 GB repository.

### The whole home directory is a source (added 2026-08-04)

`/Users/mathewcsims` is itself a Kopia source, media included, so **nothing
on the Mac has Time Machine as its only backup**. The per-app sources are
kept as well as this, not instead of it — they are obvious granular restore
targets, and Kopia dedupes content, so covering the same bytes twice costs
essentially nothing in B2. Roughly 12.7 GB / 57k files after exclusions.

**Exclusions, and why each one is there** (`kopia policy show ~` for the
live list):

| Excluded | Why |
|---|---|
| `/nas-mounts/` | The SMB mount of the NAS — not this Mac's data, and where the Time Machine sparsebundle lives. Re-including it recreates the 40-hour hang described above. |
| `/Library/CloudStorage/` | **128 GB apparent, 7.9 MB on disk** — Proton Drive placeholders. Reading them makes macOS hydrate the lot from the cloud. Already offsite in Proton Drive anyway. |
| `/Library/Mail/`, `/Library/Messages/` | **Deliberate, not a limitation** — Mathew doesn't use Apple Mail or Messages. Thunderbird is the real mail store here and *is* backed up. |
| `/Pictures/Photos Library.photoslibrary/` | **Deliberate** — Photos isn't used; photographs live in Immich, which is itself a Kopia source on slartibartfast. (The local library is an empty shell: 406 files, 82 KB.) |
| `/Library/` | 803 paths under here are unreadable even with Full Disk Access, and none of them is user data — see below. Its valuable parts are separate sources instead. |
| `.cache`, `.npm`, `.ollama`, `.minutes/models`, `go/pkg`, `.local/share/containers`, `.Trash`, `Library/Caches`, `Library/Logs`, `Library/pnpm` | ~60 GB of regenerable machine state. The podman VM images alone are 31 GB and are rebuilt from the compose files plus the app data already backed up. |

Because `/Library/` is excluded from the home source (see below), its
valuable parts are separate sources:

| Source | Size | Own exclusions |
|---|---|---|
| `~/Library/Thunderbird` | 5.1 GB — the real mail store on this Mac | none |
| `~/Library/Application Support` | ~16 GB of app data | 11 Apple-owned subdirectories |
| `~/Library/Keychains` | 14 MB | none |
| `~/Library/Preferences` | 2.8 MB | 6 Apple-owned plists |

`Containers` and `Group Containers` are deliberately NOT included: between
them they are almost entirely Apple sandbox state and the 671 protected
metadata files described below.

#### Full Disk Access is granted to kopia, and `/Library/` is STILL excluded

**FDA granted 2026-08-04.** It genuinely helps — it is what lets kopia read
`~/Library/Application Support`, `Containers`, `Thunderbird`, `Keychains`
and `Preferences` at all. But it does **not** make `~/Library` snapshottable
as a whole, and the numbers are worth recording because the intuition is
wrong:

- Before FDA, a scan found **127** unreadable directories.
- After FDA, a `kopia snapshot estimate` reported just **1**.
- A real `kopia snapshot create` with `/Library/` included then hit **803**.

The estimate undercounts badly: it stops descending a branch at the first
failure, so it sees the top of each blocked tree and nothing beneath. Only
a real snapshot enumerates the true set — worth remembering before trusting
a dry run here.

Of those 803: **671** are a single per-app file
(`.com.apple.containermanagerd.metadata.plist`, one for every sandboxed app
installed), and the remaining **132** are Apple's own service state — Siri,
Spotlight, HomeKit, Weather, Suggestions, `Group Containers/com.apple.*`,
and the sandbox containers of Apple apps. macOS protects all of it beyond
FDA, none of it is user data, and the set grows with every application
installed.

So `/Library/` stays excluded wholesale, and the parts worth restoring are
named as their own sources instead — each with a small ignore list for the
Apple-owned items inside it, which is what keeps the nightly run at **zero
errors**. Zero errors is not cosmetic here: it is the signal the verifier
trusts, so anything that makes errors routine would quietly disable the
check.

If it ever needs re-granting: System Settings ▸ Privacy & Security ▸ **Full
Disk Access** ▸ `+` ▸ `/opt/homebrew/bin/kopia` (⌘⇧G to type the path).

**Two traps worth knowing, both hit while setting this up:**

1. **TCC grants are per-binary, and attach to the *responsible* process.**
   Testing with `ls` from a shell still reports `Operation not permitted`
   even when kopia itself can read the path perfectly — the responsible
   process for a terminal command is the terminal, which has no grant. The
   only meaningful test is running **kopia itself, from launchd**, which is
   how the nightly job runs. Verified that way here: `ls` could not read
   the Photos library while kopia, under launchd, read all 406 files of it.
2. **`/opt/homebrew/bin/kopia` is a symlink** into a versioned Cellar path
   (`/opt/homebrew/Cellar/kopia/<version>/bin/kopia`). A `brew upgrade
   kopia` changes that target, which can silently invalidate the grant. If
   `~/Library` suddenly starts erroring after an upgrade, re-grant first
   before assuming anything is broken.

To enumerate what is still blocked without uploading anything, temporarily
tolerate directory errors so the scan reports instead of aborting on the
first one — then **put it straight back**, because leaving it on turns
unreadable data into a silently "clean" snapshot and makes the verifier's
zero-error check meaningless:

```sh
kopia policy set ~ --ignore-dir-errors=true
kopia snapshot estimate ~ 2>&1 | grep 'operation not permitted'
kopia policy set ~ --ignore-dir-errors=false   # DO NOT SKIP
```

### Why there is no NAS source any more (removed 2026-08-04)

`kopia-mac/backup.sh` used to mount the NAS's `AppleBackups` share and
snapshot it. That share contains exactly one thing:
`heartofgold.sparsebundle` — the Mac's **live Time Machine destination**.
This could never have worked:

- Its own `Info.plist` declares a **16 TB** image in **1.35 GiB bands**. It
  is held under a `lock` file, and Time Machine writes into it roughly 20
  hours a day (confirmed live: `tmutil status` showed `BackupPhase =
  Copying` with ~20h remaining). Copying bands file-by-file over SMB while
  they mutate cannot produce a consistent image — a restored bundle would
  not mount. It was never a usable backup, only an expensive one.
- It hung, in uninterruptible I/O (`state U`, frozen CPU time), taking the
  whole nightly job — and every subsequent night — down with it. Clearing
  the 40-hour hang needed `kill -9`; `SIGTERM` was not enough.
- Even its "successful" runs reported errors and captured a fraction of the
  source.

**This is not a coverage gap.** Time Machine still protects the Mac locally,
and Kopia already backs up the real data from the source directories
themselves. Removing it deleted a backup-of-a-backup that could not restore.
If an offsite copy of Time Machine history is ever wanted, it belongs on the
NAS itself — replicating that share on its own schedule, where the bundle
can be quiesced — not on a client copying a live image over SMB.

Removing it also removed the only use of Proton Pass in `backup.sh` (the
"NAS Eddie" item held the SMB password). The item itself is retained; Kopia
needs no secrets, and `scripts/dump-databases.sh` reads database credentials
from each container's own environment.

**Two guards were added so no future source can repeat this:**

- **A single-instance lock.** If a previous run is still alive, tonight's
  run alerts instead of exiting quietly — because while that process lives,
  launchd will not start the job again, so backups stay stopped. A stale
  lock (holder killed, as happened clearing the hang) is detected by PID
  liveness and reclaimed, so a crash cannot lock out every future run.
- **A per-source timeout** (90 minutes, ~9x the slowest healthy source), so
  one bad source is killed and *recorded as failed* rather than blocking
  every source after it. macOS ships no `timeout(1)`, so this backgrounds
  kopia and arms a killer process; the killer leaves a marker file before
  killing, because after `wait` reaps the child a kill and an ordinary
  failure are indistinguishable.

Honest limitation: a process stuck in uninterruptible I/O does not die on
`SIGKILL` until the I/O returns, so the timeout alone cannot guarantee
escape. That is why this is layered — the source that could do that is gone,
the timeout catches ordinary hangs, and the single-instance guard means an
unkillable wedge is *reported the next night* rather than silently costing
weeks of backups.

**Real access control on the web UI is a username+password** (`--server-username`/
`--server-password`, HTTP basic auth against Kopia's own auth, not the
full multi-user `kopia server user add` system — this is a single-person
setup, so the simpler mode is enough). The LAN-gate is defense in depth on
top of that, same reasoning as every other admin surface in this repo — but
more so here: this UI can browse, restore, and delete every backup this
whole stack has.

**TLS, unlike every other backend in this Caddyfile:** Kopia's web/API server
needs a real (if self-signed) TLS cert to work correctly — `--insecure` and
`--disable-csrf-token-checks` both turned out to be dev/debug-only flags in
Kopia's own source (confirmed directly:
`// disable CSRF token checks - used for development/debugging only`), not
something to copy from a docs example into production. `--tls-generate-cert`
creates a self-signed cert on first boot only (must be omitted on later
boots, or the server refuses to start — `kopia-server/entrypoint.sh` handles
this by checking whether the cert file already exists). Caddy connects to it
over HTTPS with `tls_insecure_skip_verify`, same pattern as the `mc37`
router-admin block.

**The `kopia/kopia` Docker image's own `ENTRYPOINT` is just the bare `kopia`
binary** (confirmed from its `tools/docker/Dockerfile`) — no repository
connect/create logic built in. `kopia-server/entrypoint.sh` handles the
one-time bootstrap: try `kopia repository connect b2` first, fall back to
`kopia repository create b2` if that fails (meaning no repository exists yet
at this bucket — true only for the very first machine to ever touch it),
then set the global retention policy, set this Pi as maintenance owner, and
configure + run an initial snapshot for every directory under `/data/`.

**Retention policy** (set globally, once, during first-ever bootstrap —
adjustable later from the web UI): keep the 5 most recent snapshots, 30
daily, 12 weekly, 24 monthly, 3 annual. All sources snapshot once daily.

**Known future migration:** every operation currently logs `The B2 storage
provider is deprecated and will be removed in the future, use the
S3-compatible storage provider instead` — Kopia's own native `b2` backend
(what `kopia repository create/connect b2` uses) is being phased out in
favor of connecting to B2 via its S3-compatible API instead (Kopia's `s3`
backend, pointed at B2's S3 endpoint). Not urgent — `b2` still works fully
today — but expect to migrate the repository connection (not the data
itself) to `s3` at some point before `b2` is actually removed.

**Secrets, spread across two Proton Pass items** (kopia-server needs both,
which is why it has its own deploy script rather than reusing the
one-item-per-app convention):
- **"Kopia"** — `REPOSITORY_PASSWORD` (the actual encryption key for every
  snapshot — lose it and the backup is unrecoverable; leak it and every
  backed-up file is exposed), `SERVER_CONTROL_PASSWORD` (for
  `kopia server refresh`/admin control commands), `WEBUI_PASSWORD` (the
  actual web UI login). All three generated by
  `scripts/pass-create-kopia-secrets.sh` — no values typed anywhere, pure
  `openssl rand` output piped straight into the Pass item.
- **"Backblaze B2"** — `B2_BUCKET`, `B2_KEY_ID`, `B2_APPLICATION_KEY`
  (scoped to just this bucket, not a master key). Created via
  `scripts/pass-import-b2-credentials.sh`, which prompts interactively
  (`read -s` for the hidden fields) — nothing passed as a script argument.
- **"NAS Eddie"** — `NAS_HOST`, `NAS_SHARE`, `NAS_USER`, `NAS_PASSWORD` for
  the NAS's SMB share. Created via `scripts/pass-import-nas-credentials.sh`,
  same interactive-prompt pattern. **No longer used by any job** — the NAS
  source was removed from `kopia-mac/backup.sh` on 2026-08-04 (see "Why
  there is no NAS source any more" above). Retained because the credential
  is still the NAS's, and mounting that share by hand still needs it.

**`pass-cli item create --from-template` echoes the created item — including
every field value — back to stdout.** `pass-create-kopia-secrets.sh`'s final
command was missing the redirect for this, found only because the same bug
in a newly-written sibling script (`pass-create-timetagger-secrets.sh`)
printed a freshly-generated secret straight into a Claude Code tool result.
Fixed by appending `>/dev/null` to that command; both scripts now suppress it.
An audit turned up no evidence any of the three Kopia secrets had actually
leaked anywhere retrievable (shell history only ever records the command
line, never output; nothing had run this script through a tool that logs
stdout) — but all three were rotated anyway, cheaply, for certainty.

**Rotating `REPOSITORY_PASSWORD`, `SERVER_CONTROL_PASSWORD`, and
`WEBUI_PASSWORD`:** `kopia repository change-password` changes the
repository-side password in place — no re-upload, no snapshot loss, because
the password only unwraps a locally-cached master key rather than encrypting
content directly. Run it from any already-connected client (the Mac, since
`kopia-mac`'s connection is already live and interactive):
```sh
KOPIA_NEW_PASSWORD=<new-repository-password> kopia repository change-password
```
then write the three new values onto the existing "Kopia" Pass item with
`pass-cli item update` (same `>/dev/null` discipline as creation — confirmed
`item update` echoes fields back too).

**This only refreshes the client that ran it.** Every other client/server
sharing the repository keeps its own separately-persisted local connection
state and does NOT pick up the new password just because the env var
changed — confirmed directly: redeploying `kopia-server` on the Pi with the
new `REPOSITORY_PASSWORD` alone left it crash-looping with `unable to create
format manager: invalid repository password`, because its local
`config/repository.config` and cached `cache/kopia.repository`/
`cache/kopia.blobcfg` were still keyed to the old password. Fix: stop the
container, move those four files aside (rename, don't delete — keep them as
a backup until the fix is confirmed working), then redeploy. `entrypoint.sh`'s
existing bootstrap-if-missing logic (see below) sees no config, runs `kopia
repository connect b2` fresh against the already-rotated repository, and
comes back up clean — a `connect`, not a `create`, so no data is touched.

**Historical: how the NAS mount handled its password.** Kept because the
launchd lesson generalises to every scheduled job here, even though the
mount itself is gone (see "Why there is no NAS source any more" above).

`mount_smbfs` only ever takes credentials via its URL argument — there is no
piped-input alternative — so a macOS Keychain lookup was tried first,
specifically to keep the password out of `ps` output. It worked perfectly
by hand in a real Terminal session, then failed on the first two actual
overnight `launchd` runs with the same "Authentication error" a plain
non-interactive shell gets: macOS's Keychain access control treats a
launchd-spawned process differently from a Terminal-attached one, and no
reliable way was found to grant a headless job the same access. `backup.sh`
therefore fetched `NAS_USER`/`NAS_PASSWORD` from Pass instead, accepting a
once-daily appearance in `ps` on a single-user Mac.

**The transferable lesson: test scheduled jobs by triggering them through
launchd, not by running them in a terminal.** The same class of difference
bit the `PATH` in this job's own plist (podman not found, so three database
dumps silently produced nothing) and would have bitten the verifier's plist
too — which is why that one was proved with `launchctl start` rather than a
shell run.

- `backup.sh` auto-logs-in to `pass-cli` the same way the deploy scripts do
  (`SECRET_ACCESS_TOKEN` from the repo-root `.env`) if no session is
  already active, since a scheduled 2am job can't assume one.

**To bring the Pi side up on a fresh machine:**
1. Generate the three Kopia secrets and import the B2 credentials —
   run these yourself, under your own personal `pass-cli` session:
   ```
   ./scripts/pass-create-kopia-secrets.sh
   ./scripts/pass-import-b2-credentials.sh
   ```
   (`pass-import-nas-credentials.sh` is no longer part of this setup —
   nothing mounts the NAS any more. It still exists for the item itself.)
2. **Pi:** copy the `kopia-server/` folder over (`scp -r`), then deploy with
   secrets merged from both Pass items:
   ```
   ./scripts/pass-deploy-kopia-server.sh mathew@babel '~/kopia-server'
   ```
   Quote the tilde — same reasoning as the Vikunja webhook relay's redeploy
   command. First deploy auto-builds the image; after editing
   `entrypoint.sh`/`Dockerfile`, rebuild explicitly with
   `docker compose build` first (no secrets needed for a build step), then
   redeploy through the script above so the recreated container gets the
   real secrets injected — a bare `docker compose up -d` on its own will
   blank every Pass-sourced env var, including `KOPIA_PASSWORD`.
3. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
4. **DNS:** its own explicit `A` record for `backup.mathewcsims.uk`, plus a
   NextDNS rewrite → `10.0.1.19` for LAN clients (see "Accessing from inside
   your own LAN" above for what this does and doesn't guarantee).

**To bring the Mac side up on a fresh machine:**
1. `brew install kopia`.
2. Connect to the same repository (interactively, one time — fetches the
   repository password and B2 credentials from Pass, never printed):
   ```sh
   KOPIA_PASSWORD="$(pass-cli item view --vault-name "Self-Hosted Secrets" --item-title Kopia --output json | python3 -c '...REPOSITORY_PASSWORD...')" \
   B2_BUCKET="..." B2_KEY_ID="..." B2_APPLICATION_KEY="..." \
   kopia repository connect b2 --bucket="$B2_BUCKET" --key-id="$B2_KEY_ID" --key="$B2_APPLICATION_KEY" --override-hostname=mathews-mac
   ```
   (`--override-hostname` gives this Mac's snapshots a clean, stable name in
   the shared repository, instead of whatever macOS calls the machine.)
3. Install **both** LaunchAgents — the backup and the thing that proves it
   worked:
   ```
   cp kopia-mac/uk.mathewcsims.kopia-mac-backup.plist ~/Library/LaunchAgents/
   cp kopia-mac/uk.mathewcsims.kopia-verify.plist     ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/uk.mathewcsims.kopia-mac-backup.plist
   launchctl load ~/Library/LaunchAgents/uk.mathewcsims.kopia-verify.plist
   ```
   Backup runs daily at 02:00 (see `kopia-mac/backup.sh` for the exact
   source list); verification at 06:00, after the Pi and slartibartfast have
   finished too. Neither needs Pass access at run time — `kopia repository
   connect`, done once above, persists locally, and no job mounts the NAS
   any more.

   **Prove the agents work by triggering them through launchd**, not by
   running the scripts in a terminal — `launchctl start <label>`, then check
   the exit status in `launchctl list`. A launchd job gets a minimal `PATH`
   and a different security context; both differences have caused real
   silent failures here (see the historical note above).

**Offline copy on an external HDD — now automatic on connect.**
`scripts/mirror-backup-to-external-drive.sh` mirrors the entire B2 bucket
(already encrypted by Kopia — no extra encryption needed) onto a drive. It
can still be run by hand:
```
./scripts/mirror-backup-to-external-drive.sh /Volumes/YourDriveName
```
but since **2026-08-04** it also runs on its own, driven by
`kopia-mac/mirror-on-connect.sh` and the `uk.mathewcsims.kopia-mirror`
LaunchAgent.

**Why it had to stop being manual.** This mirror is the *second copy* for
the Pi's and slartibartfast's data — those hosts write only to B2, so
everything on them is one provider away from total loss without it. The Mac
is fine either way, because Time Machine covers it too. When the automation
was written, the mirror on the drive was from **2026-07-05**: a month
stale, holding 9.8 GB of a repository that had grown well past that. A
second copy that depends on remembering is not a second copy.

**How the trigger works.** The agent uses `WatchPaths` on `/Volumes` rather
than a schedule, because the trigger is an event — the drive becoming
available — not a time. launchd fires the job on any volume mount or
unmount, which happens often and mostly for irrelevant reasons (Time
Machine mounting its own sparsebundle, disk images opening), so the script
decides whether there is anything to do:

- **The drive identifies itself.** No volume name is hardcoded. The script
  looks for any mounted volume already containing a `kopia-mirror/`
  directory — exactly what the mirror script creates. So the drive can be
  renamed or replaced without editing anything: create `kopia-mirror` on
  the new one and it is adopted. A volume *without* it is never written to,
  so plugging in an unrelated disk cannot start a 70 GB sync onto it.
- **Rate-limited to one run per 20 hours**, so repeated mount events do not
  restart an expensive sync.
- **Single-instance lock**, same mkdir-atomic pattern and stale-lock
  reclaim as `kopia-mac/backup.sh`.
- **State is written only on success**, to `kopia-mac/.mirror-state`. A
  failed run must not look like a fresh mirror, or the staleness warning
  below quietly stops working.
- `RunAtLoad` is set too, so a drive left permanently connected is still
  mirrored rather than waiting for a mount event that never comes.

**The nightly verification reports how stale it is.** `verify-backups.sh`
reads that state file and includes the mirror's age in the nightly
notification, warning past `MIRROR_MAX_AGE_DAYS` (14). It is deliberately
**not** a hard failure: a stale mirror does not mean tonight's backups are
bad, and conflating the two would make the nightly result useless for its
main job. Without this, "two copies of everything" silently degrades to one
the moment the drive stops being plugged in — which is the exact class of
silent failure the verifier exists to catch.
Uses `rclone sync` (not `copy`) so the drive stays an *exact* mirror,
including deletions — not an ever-growing pile of old copies. Credentials
flow the same way as everywhere else: fetched from the "Backblaze B2" Pass
item, passed to `rclone` purely as `RCLONE_B2_ACCOUNT`/`RCLONE_B2_KEY`
environment variables (`RCLONE_CONFIG=/dev/null` so no `rclone.conf` is
ever read or written), confirmed working directly against the live bucket
rather than assumed from rclone's docs (which don't actually show this
exact on-the-fly connection-string form).

**Restoring from the external drive is NOT a direct `kopia repository
connect filesystem` against the mirrored folder** — tested this directly
and it fails with `repository not initialized in the provided storage`,
despite every file being present and intact. The cause: Kopia's filesystem
backend expects every blob file to carry a `.f` suffix and live in a
nested shard directory (e.g. `q/f8a/919e6d...-....f`) — a purely local-disk
convention that B2's flat, unsharded object-key storage never used, so the
mirrored files (named exactly as B2 stored them, flat, no suffix) don't
match what the filesystem backend goes looking for. Kopia does ship an
`rclone` repository backend that side-steps this, but it's explicitly
marked `[Not maintained]` in Kopia's own CLI help — not something to build
a disaster-recovery procedure around.

**The verified, reliable restore path:** since the mirrored data is already
shaped exactly right for a `b2`-type connection (unchanged since it came
from B2), sync it back up to a bucket — the original one if it's still
reachable, or a fresh one if not — and connect normally:
```sh
# 1. Create (or reuse) a B2 bucket + application key, and get the
#    repository password from the "Kopia" Pass item's REPOSITORY_PASSWORD
#    field. This is the one real dependency this whole procedure has: you
#    need Proton Pass access to retrieve it, so it's worth knowing that's
#    the case rather than assuming the drive alone is fully sufficient.

# 2. Push the mirror back up (same rclone env-var pattern as the mirror
#    script itself, just reversed):
RCLONE_B2_ACCOUNT=<key-id> RCLONE_B2_KEY=<application-key> RCLONE_CONFIG=/dev/null \
    rclone sync /Volumes/YourDriveName/kopia-mirror :b2:<bucket-name>

# 3. Connect exactly as any other machine would:
KOPIA_PASSWORD=<repository-password> \
    kopia repository connect b2 --bucket=<bucket-name> --key-id=<key-id> --key=<application-key>

# 4. Browse and restore:
kopia snapshot list
kopia restore <snapshot-id> /path/to/restore/to
```
This needs internet access to re-upload the mirror (the same ~10 GiB+ it
took to download it, scaling with however much has accumulated by the time
of a real restore) — a real cost, but a far more modest ask than needing
the original Pi or Mac to still exist, and it only relies on Kopia's
actively-maintained, everyday `b2` backend rather than an edge case nobody
else is really using.

**Verifying restores (periodic testing):** it is NOT enough to confirm that
backups are running and data is being uploaded — the only way to know a backup
is actually usable is to test restoring from it. A bug in the backup process,
a corruption in the repository, or a lost encryption key would only be discovered
when you actually need the backup, which is the worst possible time. Schedule
a restore test **at least quarterly** (monthly is better for critical data),
and always after any major infrastructure change (Kopia upgrade, B2 configuration
change, etc.).

Run a **test restore** like this (example for the Mac's `karakeep/data`):
```sh
# 1. List available snapshots for the source you want to test
KOPIA_PASSWORD="$(pass-cli item view --vault-name "Self-Hosted Secrets" --item-title Kopia --output json | python3 -c 'import json,sys;d=json.load(sys.stdin);print([f["value"] for s in d["item"]["content"]["content"]["Custom"]["sections"] for f in s["section_fields"] if f["name"]=="REPOSITORY_PASSWORD"][0])')" \
  kopia snapshot list --all | grep karakeep/data

# 2. Pick a recent snapshot ID and restore it to a temporary location
#    (replace <snapshot-id> with an actual ID from the list above)
TEST_RESTORE_DIR="/tmp/kopia-test-restore-$(date +%Y%m%d)"
KOPIA_PASSWORD="..." kopia restore <snapshot-id> "$TEST_RESTORE_DIR"

# 3. Verify the restore succeeded and the data is intact
ls -la "$TEST_RESTORE_DIR/karakeep/data"
# Check a few sample files match expectations (size, type, content)
file "$TEST_RESTORE_DIR/karakeep/data/..."  # verify file types
sha256sum "$TEST_RESTORE_DIR/karakeep/data/..."  # compare with known good

# 4. Clean up the test restore
rm -rf "$TEST_RESTORE_DIR"
```

**What to test:**
- Every backed-up application directory, at least once per year
- Critical data (Vikunja, Forgejo repos, Ghost content) every quarter
- Pi-resident app data at least annually

**Automating the check:** add a `test-restore` target to `kopia-mac/backup.sh`
that performs a lightweight restore of one or two non-critical paths (e.g.
`speedtest-tracker/config`) after each successful backup, and alerts if it
fails. A full restore of every path is too heavy for daily automation, but a
spot-check of a few paths catches most failures.

**Documenting results:** keep a simple log of restore tests (date, what was
tested, success/failure) — e.g. append to `kopia-mac/restore-test.log`. This
provides audit evidence and helps track test frequency.

---

## TimeTagger (https://time.mathewcsims.uk) — DECOMMISSIONED

> **DECOMMISSIONED 2026-08-04.** Torn down for lack of use (zero time
> records logged). Containers, images, volumes, networks, the Caddy site
> block, the Uptime Kuma monitor and the DNS records are all gone;
> `timetagger/` was removed from this repo and survives only in git history.
> The section below is kept verbatim as the rebuild recipe. A final database
> dump and a cold `tar.gz` of the whole data directory live in
> `db-dumps/decommissioned/` on the Mac, and the **TimeTagger** Proton Pass
> item was deliberately retained — between them, everything needed to stand
> this back up still exists.


Tag-based time tracker (https://github.com/almarklein/timetagger), Mac-resident.

**No native OAuth — confirmed directly from its source.** TimeTagger's only
login methods are a local bcrypt password (`TIMETAGGER_CREDENTIALS`, left
unset here so this path has zero valid users) or trusting a username handed
to it via a header from a reverse proxy it's told to trust by source IP
(`TIMETAGGER_PROXY_AUTH_*`, intended for pairing with something like
Authelia). Getting real Infomaniak SSO — the same idea as Nimbus's native
OIDC, above — means something else has to actually do the OIDC exchange
and hand TimeTagger a verified identity. That is
[oauth2-proxy](https://github.com/oauth2-proxy/oauth2-proxy), running as a
sidecar in `timetagger/compose.yaml`.

**Architecture:**

```
Caddy (Pi) → oauth2-proxy (Mac, LAN-IP:4180, published) → TimeTagger (Mac,
             internal network only, no port published at all)
```

oauth2-proxy runs in full reverse-proxy ("upstream") mode, not the
nginx-style auth_request/forward_auth sidecar mode — every request hits
oauth2-proxy first; unauthenticated ones get redirected to Infomaniak, and
only requests it has itself verified are forwarded to TimeTagger, with
`X-Forwarded-Email` set to the verified address (oauth2-proxy's own
default behavior). This is the crux of the whole setup's security:
TimeTagger's proxy-auth trust check is "believe whatever username shows up
in a header, if the request's source IP is on an allowlist" — get that
allowlist wrong and anyone who can reach TimeTagger directly can set the
header themselves and log in as you. So TimeTagger publishes no port at
all, to the LAN or otherwise, and only exists on a private `internal`
compose network; oauth2-proxy holds a static IP on that same network
(`10.89.90.2`, via a fixed `10.89.90.0/28` subnet — chosen well clear of
podman's own sequential auto-assigned `10.89.<n>.0/24` project networks),
and `TIMETAGGER_PROXY_AUTH_TRUSTED` is that exact IP, not a range.

**Login is restricted to one specific address, not "any Infomaniak user."**
`login.infomaniak.com` is Infomaniak's identity service shared across all
its customers (confirmed via the discovery document when Nimbus was set
up) — a bare "successful OIDC login" check would let any Infomaniak
customer worldwide in. `OAUTH2_PROXY_EMAIL_DOMAINS` would be equally wrong
for the same reason. Instead this uses
`OAUTH2_PROXY_AUTHENTICATED_EMAILS_FILE`, a file with exactly one allowed
address, which oauth2-proxy's own validator ORs with `EMAIL_DOMAINS`
(confirmed from source) — so leaving `EMAIL_DOMAINS` unset makes the
email-allowlist file the only path to a valid login. That file
(`timetagger/oauth2-proxy/authenticated-emails.txt`) is not committed —
`scripts/pass-deploy-timetagger.sh` writes it at deploy time from the
"TimeTagger" Pass item's `ALLOWED_EMAIL` field (oauth2-proxy has no
env-var equivalent — confirmed from source — so this is the one thing
`pass-deploy.sh`'s generic pattern cannot do, hence the bespoke script,
same class of per-app variant as `pass-deploy-kopia-server.sh`).

**Images:** both pinned to exact digests, not `:latest` — oauth2-proxy
v7.15.3 is the first release with several real fixes (a critical auth
bypass via `X-Forwarded-Uri` spoofing, a critical `auth_request`-mode
bypass, an email-domain bypass via malformed multi-`@` claims — confirmed
via GitHub's security-advisories API). TimeTagger runs the plain root-user
image, not the `-nonroot` variant: the nonroot image was tried first (uid
1000, matching the "avoid unnecessary root" reasoning used for
Vikunja/copyparty) but failed live — podman-machine's rootless remapping
only maps a container's ROOT user to your host user for sane bind-mount
ownership (see Vikunja's own compose.yaml comment), not a fixed non-root
uid, so uid 1000 could not write the bind-mounted data directory.

**Bring-up:**

1. Register a new OIDC application in Infomaniak's IK-AUTH
   (`manager.infomaniak.com` → your account → Cloud/IK-AUTH) — a separate
   client from Nimbus's, so each app's grant is independent. Redirect URI
   must be exactly `https://time.mathewcsims.uk/oauth2/callback`.
2. `./scripts/pass-create-timetagger-secrets.sh` — generates
   `OAUTH2_PROXY_COOKIE_SECRET` and creates the "TimeTagger" Pass item with
   placeholder `OIDC_CLIENT_ID`/`OIDC_CLIENT_SECRET` and a default
   `ALLOWED_EMAIL`.
3. Set the real client ID/secret from step 1 on that Pass item (correct
   `ALLOWED_EMAIL` too, if it should not be the default):
   ```
   pass-cli item update --vault-name "Self-Hosted Secrets" --item-title "TimeTagger" \
       --field OIDC_CLIENT_ID=... --field OIDC_CLIENT_SECRET=...
   ```
4. `./scripts/pass-deploy-timetagger.sh` — writes the email-allowlist file
   and brings the stack up. **Never** `podman compose up -d` directly here
   (same rule as every other Pass-backed app) — it blanks every secret.
5. Verify: `curl -s -o /dev/null -w '%{http_code}\n' http://<mac-lan-ip>:4180/oauth2/start`
   should 302 to `login.infomaniak.com/authorize` with the right client ID
   and redirect URI. A direct request to `<mac-lan-ip>:8080` (TimeTagger's
   internal port) should fail to connect at all — if it does not, the
   security boundary above is not actually in place.

**Backup:** `timetagger/data/` (TimeTagger's own datadir, holding per-user
SQLite-backed time entries) is in `kopia-mac/backup.sh`'s `SOURCES` list.

---

## BookStack (https://author.mathewcsims.uk) — LAN-only, runs on the Mac

[BookStack](https://www.bookstackapp.com) — project wiki for writing
projects (its Shelf → Book → Chapter → Page taxonomy maps directly onto
"project → draft" without needing custom structure). Two containers on the
Mac, MariaDB sidecar like Ghost's MySQL one — BookStack has no sqlite
option, unlike Vikunja/Memos.

**Deliberately LAN-only, not internet-facing-with-a-login** — same pattern
as Speedtest Tracker: a real public `A` record and Caddy-issued Let's
Encrypt cert exist (BookStack's `APP_URL` always redirects to
`author.mathewcsims.uk` regardless of what Host header a request arrives
with, so the cert has to be for that exact name — a direct request to the
Mac's LAN IP just redirects into a dead end until DNS/Caddy are live), but
`pi-reverse-proxy/Caddyfile`'s `author.mathewcsims.uk` block gates on
`remote_ip private_ranges 100.64.0.0/10` (the Tailscale CGNAT range,
included for the same reason as Speedtest/mc37) and `abort`s any non-LAN
source before it ever reaches the app — confirmed by inspecting Caddy's
live JSON config (`docker exec caddy wget -qO- http://127.0.0.1:2019/config/`),
not just assumed from the Caddyfile text.

**No SSO** — single-user, LAN-only, so the extra Infomaniak app
registration wasn't worth it; a local admin password is enough here.
BookStack does support OIDC (`AUTH_METHOD=oidc`) if that ever changes, with
one gotcha worth remembering: it won't auto-link an OIDC login to an
existing local account just because the email matches — you'd need to log
in once as the local admin and set that account's "External Authentication
ID" first, same class of pitfall as Memos' SSO linking (see Marque above).

**The default-admin problem, and how it differs from Vikunja/Speedtest:**
BookStack ships a fixed, publicly-documented default admin
(`admin@admin.com` / `password`) with **no supported env-var override** to
set custom initial credentials (confirmed against BookStack's own docs —
unlike Vikunja's CLI-created admin or Speedtest's `ADMIN_EMAIL`/
`ADMIN_PASSWORD` env vars). The only way to change it is through the app's
own Edit Profile screen — entering credentials into that form is something
only you should do, not something to script or automate. Practical
sequence actually used here: deployed the containers first with the Caddy/
DNS layer already live (LAN-gate already enforcing, so the exposure window
was only to devices on the home network/tailnet, briefly, not the whole
internet — direct-IP access before DNS existed doesn't actually work
anyway, since `APP_URL` forces every response to redirect to the real
hostname), then you logged in once via `https://author.mathewcsims.uk` and
changed the email/password immediately.

**Image**: `lscr.io/linuxserver/bookstack`, pinned to `26.05.2` by digest.
Checked GitHub Security Advisories for `BookStackApp/BookStack` directly:
one real recent one, CVE-2026-5484 (auth bypass in the chapter Markdown
export handler — bypasses page-level view permissions when exporting a
chapter), fixed at 26.03.1; 26.05.2 is well past it. MariaDB is the official
`mariadb:11.4.12` image (LTS, maintained until 2029), also pinned by digest.

**Hardening, all in `bookstack/compose.yaml` and the Caddyfile block:**
- `APP_KEY` and both DB passwords generated via
  `scripts/pass-create-bookstack-secrets.sh` (Laravel key in the standard
  `base64:` + 32-random-bytes format; DB passwords alphanumeric-only,
  avoiding compose's `${VAR}` escaping problems entirely rather than
  working around them).
- `PUID`/`PGID` set to `1000:1000` — linuxserver's baseimage runs the app
  as this fixed UID/GID rather than root, so (unlike copyparty, which
  benefits from podman-machine's automatic root→host-user remap) `./config`
  needs pre-chowning before first boot, same fix as Vikunja's
  `./files`/`./db` needed:
  ```sh
  podman run --rm -v "$PWD/config:/config" docker.io/library/alpine:latest \
    chown -R 1000:1000 /config
  ```
- Self-registration confirmed closed (`/register` redirects to `/login`) —
  BookStack's own default, verified rather than assumed.
- Security headers apply (`import security_headers`), plus two rate-limit
  zones: a general 300/min budget, and a tighter 10/min zone on `POST
  /login` specifically — no other app in this repo has a plain
  username+password login form with no built-in rate limiting of its own
  (everything else either has its own, like Karakeep/Memos, or uses SSO),
  so this is the first Caddy-layer login-specific zone written from
  scratch rather than adapted from an existing one.

**API access, for Claude Code use:** BookStack has a mature REST API
(`/api/books`, `/chapters`, `/pages`, `/shelves`, `/search`, token auth via
`Authorization: Token <id>:<secret>`). Rather than run one of the several
community MCP servers for it (extra unaudited process, extra thing to
patch, for no benefit when the consumer is Claude Code itself), the token
lives in the "BookStack" Proton Pass item (`TOKEN_ID`/`TOKEN_SECRET`,
generated once via Edit Profile → API Tokens → Create Token) and a Claude
Code skill at `.claude/skills/bookstack-api/SKILL.md` documents the
endpoints directly — same "call the API with curl" pattern as every other
admin script in this repo, no new service to trust.

**To bring it up:**
1. `./scripts/pass-create-bookstack-secrets.sh` — creates the "BookStack"
   Proton Pass item (`APP_KEY`, `DB_ROOT_PASSWORD`, `DB_PASSWORD`).
2. **Mac:** pre-chown `bookstack/config` (see above), then
   `./scripts/pass-deploy.sh bookstack BookStack` (explicit item-title
   argument needed — the default title-from-dirname logic produces
   "Bookstack", not "BookStack").
3. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and reload
   Caddy (`docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`).
4. **DNS:** `./scripts/dns-digitalocean.sh add author <WAN IP>` (there is no
   blanket wildcard — every hostname needs its own record), then
   `./scripts/dns-nextdns.sh add author.mathewcsims.uk 10.0.1.19` for clean
   LAN access.
5. From your own network, visit `https://author.mathewcsims.uk`, log in
   with the default admin credentials, and change the email/password via
   Edit Profile immediately — see above for why this can't be scripted.
6. Generate an API token (Edit Profile → API Tokens) and add
   `TOKEN_ID`/`TOKEN_SECRET` to the "BookStack" Pass item.

**Backup:** `bookstack/config/` and `bookstack/db/` are in
`kopia-mac/backup.sh`'s `SOURCES` list.

---

## Forgejo (https://fj.mathewcsims.uk) — LAN-only, runs on the Mac

[Forgejo](https://forgejo.org) — self-hosted git remote + web UI, for
projects worth keeping under real version control but not worth pushing to
a third-party host like GitHub. Grew out of a "what if I want git history
without third-party visibility" conversation — plain version control and
end-to-end encryption of the remote are basically incompatible if you still
want the remote to do anything useful (browsable history, a web UI), so the
answer here is "keep it entirely under your own infrastructure" instead:
same LAN-only Caddy pattern as BookStack/Speedtest, backed by the same
Kopia pipeline as everything else.

**SQLite, not a DB sidecar** — Forgejo/Gitea's own docs treat sqlite3 as a
fully supported backend for low-concurrency, single-user instances (same
reasoning as Vikunja/Memos in this repo); no MariaDB/Postgres container
needed, keeping this lighter than BookStack.

**No SSO, no default-credential window at all** — unlike BookStack,
Forgejo has a real CLI for provisioning the first account
(`forgejo admin user create`), so the single admin user is created directly
via `docker`/`podman exec` with a Pass-generated password, never through a
web form and never landing on any known-default credential even briefly.
Registration is disabled from first boot
(`FORGEJO__service__DISABLE_REGISTRATION`).

**A real gotcha caught live during setup, not from docs:** even with every
setting supplied via `FORGEJO__*` environment variables, the container's
own startup log said `Prepare to run install page` — meaning it was still
going to serve an *unauthenticated* first-run web install wizard, letting
anyone who reached it before you did configure the instance and create
their own admin account. Environment-variable config alone doesn't imply
the install is "locked" — `FORGEJO__security__INSTALL_LOCK: "true"` is
required explicitly, confirmed by re-checking the log after adding it
(`serveInstalled`/`InitWebInstalled` instead of the install-page message).

**CVE-2026-20896 (critical, 9.8, reverse-proxy-auth bypass, v15 LTS —
no backport planned, fixed properly only in v16.0.0):** exploitable only
if `ENABLE_REVERSE_PROXY_AUTHENTICATION` is turned on (letting a reverse
proxy assert user identity via an `X-WEBAUTH-USER`-style header) *and* the
web port is directly reachable from an untrusted network. Neither applies
here — plain local password auth is used instead of header-based auth, and
the web port is never directly internet-facing regardless (same LAN-gate
as everything else, plus not router-forwarded in the first place) — but
`FORGEJO__security__REVERSE_PROXY_TRUSTED_PROXIES` is still pinned to the
Pi's actual LAN IP rather than left at the image's vulnerable wildcard
default, as a deliberate backstop rather than an unexamined gap.

**Two ports, two protocols:** the web UI (`3300` on the Mac's LAN IP) goes
through Caddy same as every other app; git-over-SSH (`2222` on the Mac's
LAN IP) is reached **directly** by clients — Caddy only ever speaks
HTTP(S), so SSH push/clone bypasses it entirely rather than being proxied.
`FORGEJO__server__SSH_PORT` just controls what port Forgejo *advertises* in
clone URLs shown by the web UI; the actual external mapping is set in
`ports:` in `compose.yaml`.

**Image**: `codeberg.org/forgejo/forgejo`, pinned to `v16.0.0` by digest
(upgraded 2026-07-19 from the 15.0.x LTS line; SQLite migrations ran
cleanly on first boot). v16's breaking changes were checked and none
apply here: no repo mirrors (the `http.followRedirects=false` SSRF
hardening), reverse-proxy auth off, and `REVERSE_PROXY_TRUSTED_PROXIES`
already explicitly pinned since install — v16 merely turned that
defense-in-depth choice into the required default. Pre-upgrade Kopia
snapshot of `forgejo/data` taken (`kbd1e5ee6a4d…`) for instant rollback.

**Verified end-to-end, not just "the container is up":** registered a
throwaway SSH keypair against the admin account via the API, created a
test repo, cloned it over `ssh://git@10.0.1.14:2222/...`, pushed a commit,
confirmed it landed, then deleted both the test repo and the throwaway key
via the API afterward — proves the SSH daemon, key auth, and git
push/pull path all actually work, not just that port 2222 accepts a TCP
connection.

**Email — password resets and issue/PR notifications:** a dedicated
mailbox/credentials created specifically for this instance, deliberately
not reused from Ghost's own SMTP setup (see the Ghost section above) —
kept separate rather than sharing one mail identity across apps. Add
`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, and `MAIL_FROM` to
the existing "Forgejo" Pass item (not a new item — see `.env.example`).
STARTTLS assumed (`FORGEJO__mailer__PROTOCOL: smtp+starttls`, matching
Ghost's own port-587 STARTTLS setup) — change that in
`forgejo/compose.yaml` if the new mailbox uses implicit TLS (`smtps`)
instead. This is the reason `forgejo/compose.yaml` now has real
`${VAR}` secrets in it (it didn't originally) — deploy via
`pass-deploy.sh`, not a bare `compose up -d`, from this point on.

Verified via `forgejo admin sendmail` (run as the `git` user, same
`-u git -e HOME=/data/git` pattern as the admin-account CLI command
below). First attempt against a freshly-created Proton mailbox logged a
transient failure (`454 4.7.0 Temporary authentication failure:
Connection lost to authentication server`) — but the email still arrived,
confirming the config itself was correct and this was a one-off hiccup
(Proton SMTP app-passwords sometimes take a moment after creation), not a
real problem. Forgejo's mailer queue retried silently — no explicit
success line in the logs, only the initial failure — so don't take a
logged mail error alone as proof delivery didn't happen; check the actual
inbox.

**To bring it up:**
1. `./scripts/pass-create-forgejo-secrets.sh` — creates the "Forgejo"
   Proton Pass item with a generated `ADMIN_PASSWORD` (`ADMIN_USERNAME` is
   just `mathew`, stored alongside for convenience). Add the SMTP fields
   above to this same item before deploying.
2. **Mac:** `./scripts/pass-deploy.sh forgejo Forgejo` (explicit item-title
   argument needed, same reason as BookStack's).
3. Create the admin account via CLI, **not** the web UI:
   ```sh
   ADMIN_PASSWORD=$(pass-cli item view --vault-name "Self-Hosted Secrets" \
       --item-title "Forgejo" --output json | python3 -c '...reads ADMIN_PASSWORD...')
   podman exec -u git -e ADMIN_PW="$ADMIN_PASSWORD" -e HOME=/data/git forgejo sh -c \
       'forgejo admin user create --username mathew --password "$ADMIN_PW" \
        --email mat@mathewcsims.uk --admin --must-change-password=false'
   ```
4. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and reload
   Caddy.
5. **DNS:** `./scripts/dns-digitalocean.sh add fj <WAN IP>`, then
   `./scripts/dns-nextdns.sh add fj.mathewcsims.uk 10.0.1.19`.
6. From your own network, log into `https://fj.mathewcsims.uk` with the
   Pass-stored credentials, then add your own SSH public key under
   Settings → SSH/GPG Keys to actually use `git clone`/`push` against
   `ssh://git@10.0.1.14:2222/mathew/<repo>.git`.

**Backup:** `forgejo/data/` (SQLite DB, repo objects, SSH host keys — all
of it) is in `kopia-mac/backup.sh`'s `SOURCES` list.

### Claude Code agent access — a separate, scoped bot account

Agents need to reach Forgejo without ever using Mathew's own admin
credentials — a leaked or misbehaving agent token should only ever be able
to touch what was explicitly granted, not the whole instance. Solved with
a second, non-admin Forgejo account (`claude-agent`) and a repo/issue-
scoped API token, stored in a **separate** Pass item ("Forgejo Claude
Agent") from Mathew's own ("Forgejo") — independently revocable, and an
obviously distinct audit trail from his own activity in the web UI.

**Scope actually needed, found empirically, not just from docs:**
`write:repository,write:issue,write:user`. Forgejo's own token-scope docs
suggest `write:repository` alone covers `POST /user/repos` (creating a
repo for the authenticated user) — live-tested and that's wrong, or at
least incomplete: the request failed with a generic `token is required`
error until `write:user` was added too, at which point both repo creation
and `GET /user` started working. No `admin`/`organization`/`package`
scope at all — confirmed a request to `/api/v1/admin/users` with this
token returns 401 regardless.

**Zero access by default**: a fresh Forgejo account can't see or touch any
private repo until explicitly added as a collaborator — so `claude-agent`
starts with nothing. To let agents work on a specific existing repo, add
`claude-agent` as a Collaborator on it (Settings → Collaborators, per
repo) — there's no instance-wide grant to flip. Repos the bot creates
under its own account are usable immediately without any extra step.

**Setup:**
```sh
./scripts/pass-create-forgejo-agent-secrets.sh   # creates the Pass item, generates BOT_PASSWORD

# Create the non-admin account (no --admin flag)
podman exec -u git -e BOT_PW="$BOT_PASSWORD" -e HOME=/data/git forgejo sh -c \
    'forgejo admin user create --username claude-agent --password "$BOT_PW" \
     --email claude-agent@mathewcsims.uk --must-change-password=false'

# Generate the scoped token directly via CLI — never via a web-form login
TOKEN=$(podman exec -u git -e HOME=/data/git forgejo sh -c \
    'forgejo admin user generate-access-token --username claude-agent \
     --token-name claude-code --scopes write:repository,write:issue,write:user --raw')
pass-cli item update --vault-name "Self-Hosted Secrets" --item-title "Forgejo Claude Agent" \
    --field BOT_TOKEN="$TOKEN" >/dev/null
```

Verified end-to-end (not just "the token exists"): authenticated as
`claude-agent`, created a private test repo via the API, confirmed
`GET /api/v1/admin/users` was rejected (401) with the same token, then
deleted the test repo.

The Claude Code skill at `.claude/skills/forgejo-api/SKILL.md` documents
both the REST API and git-over-HTTPS usage (the token doubles as the git
password — no separate SSH key needed for agent use, keeping Mathew's own
SSH key exclusively his).

---

## Contact sync (no public URL — a scheduled job on the Mac, not a service)

Cross-provider address-book sync: 1 Proton (personal), 1 Google
(personal), 2 Microsoft (1 personal, 1 work). Goal: one identical
address book everywhere, with the work account participating
**asymmetrically** (see below). Nothing off-the-shelf covers this
combination — Proton has no CardDAV/official API (E2E encryption is
structurally incompatible with DAV), and the work MS tenant allows no
OAuth app registrations.

**Architecture: hub-and-spoke.** A canonical vCard store on the Mac
(`~/contact-sync/store/`, one RFC 6350 `.vcf` per contact + `state.json`
mapping canonical UID → per-provider IDs) is the hub; each provider
syncs against it independently:

| Spoke | Mechanism | Notes |
|-------|-----------|-------|
| Google | People API, OAuth desktop-app client | refresh token in Pass ("Contact Sync Google") |
| MS personal | Graph API, device-code public client | Graph rotates refresh tokens — every run stores the new one back to Pass ("Contact Sync Microsoft") |
| MS work | Thunderbird MCP extension's local HTTP API (work Exchange account, migrated from macOS Contacts.app/JXA 2026-07-25 when Mathew moved his work mail to Thunderbird) | **asymmetric**: its ~21 contacts sync outward + receive updates to those same contacts, but personal contacts are NEVER pushed into the employer's mailbox. Matching is name-based, not email-based — Thunderbird's local cache doesn't populate primary emails for these Exchange-directory contacts. Two identically-named duplicate "stfc.ac.uk Contacts" address books exist locally with no technical way to distinguish them; `thunderbird_client.WORK_ADDRESS_BOOK_ID` picks the more-recently-modified one as a documented, single-line-to-change assumption |
| Proton | unofficial [proton-cli](https://github.com/roman-16/proton-cli), audited + built from source | see audit notes below |
| iCloud | macOS Contacts.app via JXA (added 2026-07-25) | full symmetric spoke (create/update/delete), same as Google/Proton — unlike the asymmetric ms_work spoke |

The engine lives at `contact-sync/` in this repo (stdlib-only Python,
same discipline as `vikunja-webhook-relay/`); the *data* lives at
`~/contact-sync/` (outside the repo, like every app's data dir). The
store is a git repo pushed to a **private Forgejo repo**
(`claude-agent/contact-sync-store` on fj.mathewcsims.uk) — full history
of every sync run's changes, entirely on own infrastructure — and
`~/contact-sync` is in `kopia-mac/backup.sh` SOURCES.

**proton-cli audit (the gate for using an unofficial client at all):**
pinned v1.9.4 (`5f4fd10`), full source read: only network destinations
are `mail.proton.me/api` + `verify.proton.me` (CAPTCHA), crypto via
Proton's own official Go libraries (go-srp/gopenpgp), no telemetry or
update-checker, session file is 0600 with the key password encrypted
against a server-side key (revoking the session from Proton's web UI
makes the on-disk blob undecryptable), password only ever via env var.
Built from source (go.sum hash-verified); runtime traffic capture via a
local logging CONNECT proxy during the real first login confirmed
exactly one destination: `mail.proton.me:443`. One local patch
(`contact-sync/patches/proton-cli-list-full-cards.patch`, +1 line)
makes the bulk list endpoint include full decrypted vCards — 15s for
all 809 contacts instead of ~45min of per-contact gets. 2FA was needed
once, interactively, at first login; routine runs reuse the session.
As the contact count grew past ~1,025, the export's server-side
pagination pushed total `contacts list` time past the CLI wrapper's
120s subprocess timeout (confirmed live: ~145s across 13 pages, real
API latency, not a hang) — `spoke_proton.py`'s `run_cli()` timeout was
raised to 300s (2026-07-25) to give real headroom.

**Initial convergence (2026-07-18):** 1,426 records in → 1,025 canonical
contacts (merge report kept at `~/contact-sync/initial-merge-report.md`;
matching by normalized email → phone → exact ≥2-word name, ambiguous
cases surfaced for review; the four Microsoft Mobile Services
phone-backup folders were mined once for missing emails/phones — 3
recovered — and are otherwise excluded). Google, MS personal, and
Proton each hold all 1,025; the work account keeps only its own 21.
Pre-first-write snapshots of every provider are at
`~/contact-sync/snapshots/pre-first-write/`.

**Graph quirks found live:** max 3 emailAddresses / 2 businessPhones /
2 homePhones per contact (the spoke caps and compares cap-aware, so
over-cap contacts don't look perpetually out-of-sync); refresh tokens
rotate on every use (captured via fd 3); one create was silently dropped
server-side (accepted-then-vanished) and re-created on verification —
counts are always re-verified against the provider after an apply, not
trusted from API success responses.

**MS refresh-token rotation storage (fixed 2026-07-25):** `run-sync.sh`
originally tried writing each rotated token straight back to the
"Contact Sync Microsoft" Pass item, which failed every run with
`NotAllowed` — the unattended run's agent PAT is read-only by design
(see the agent access model above), it can never write to Pass, no
matter the vault or item. Fixed by caching the rotated token locally
instead, at `~/contact-sync/.ms-refresh-token` (0600, outside the repo,
covered by the existing `~/contact-sync` Kopia backup source) — each run
prefers this cache over Pass's copy, falling back to Pass only if the
cache is missing (e.g. a fresh checkout). Pass's own copy is now just
the bootstrap value and goes stale over time; that's expected, not a
problem — update it manually only if ever needed to reseed the cache
(e.g. on a new machine).

**iCloud spoke, added 2026-07-25.** Mathew's iCloud Contacts was empty
when this was added (Contacts.app showed only his own "Me" card) — the
first apply was a genuine bulk-populate of all ~620 canonical contacts
into iCloud (`contact-sync/spoke_icloud.py`), not a merge of pre-existing
data. Full symmetric spoke via JXA (`osascript -l JavaScript`), same
create/update/delete contract as `spoke_google.py`; the safety caps in
`sync.py`'s daily run would have skipped a change this large as "outbound
plan too large", so the initial populate was run directly, once, outside
the normal daily path (same pattern as `initial_merge.py`'s original
2026-07-18 convergence).

Two things learned the hard way, both now handled:
- **JXA performance**: a per-contact loop of separate `osascript`
  processes measured ~270ms/contact for reads — reading each property as
  one array across the whole `people` collection instead
  (`app.people.firstName()` etc., zipped in Python/JS) dropped that to
  ~3ms/contact. Reads, creates, updates, and deletes are each one batched
  Apple Event, not one per contact.
- **The "Me" card isn't excludable via any documented API** — no
  `myCard`/"my card" exists in JXA, classic AppleScript, or the app's own
  `sdef` dictionary. On the very first sync.py run after wiring this
  spoke in, the Me card (unmapped to any canonical contact) was pulled
  like a normal contact and treated as brand-new, propagating an empty
  duplicate "Mathew Sims" to Google/MS-personal/Proton before being
  caught and cleaned up. Fixed by hardcoding its ID as `ME_CARD_ID` in
  `spoke_icloud.py` (identified empirically — the sole pre-existing
  person before the populate) and filtering it out at the JXA read
  itself. If this Mac's Me card is ever recreated (e.g. iCloud account
  reset), the symptom — a stray near-empty self-contact appearing across
  every provider again — is the signal to update that constant.
- Canonical has no middle-name field (only given/family) — a name like
  "Arts Award College" (given="Arts", family="College") silently drops
  "Award" if written as firstName+lastName alone. `spoke_icloud._expected_name()`
  recovers it into Contacts.app's `middleName`, but only when
  given+middle+family round-trips back to the original name exactly;
  hyphenated names, honorifics ("Dr Firstname Lastname"), and org names
  correctly fall back to given+family-only rather than risk a corrupted
  reconstruction. `differs()` compares against this expected/writable
  name, not the raw canonical name, so that permanent, known-imperfect
  gap (same category as Proton's un-clearable notes field) doesn't show
  as an eternal daily "update".

**MS work migration to Thunderbird (2026-07-25):** when Mathew moved his
work account's mail/contacts management to Thunderbird, the 21 canonical
contacts linked under `sources.ms_work` still held stale macOS
Contacts.app IDs. `contact-sync/migrate_ms_work_to_thunderbird.py` (a
one-time script, `--apply` to write, dry-run by default) re-pointed them
at their new Thunderbird card UUIDs: 17 by exact normalized-name match,
4 by an explicit `MANUAL_OVERRIDES` dict confirmed with Mathew directly
(reworded names between the two systems that the automatic matcher
correctly declined to guess) — 0 left ambiguous or unresolved. Report at
`~/contact-sync/migration-report.md`; pre-migration backup at
`~/contact-sync/canonical.json.pre-thunderbird-migration.bak`. Requires
Thunderbird running with the MCP extension loaded for the launchd job to
reach it — if unavailable, `ms_work` is skipped for that run same as any
other offline spoke, everything else proceeds.

**Ongoing sync:** `contact-sync/run-sync.sh` via launchd
(`uk.mathewcsims.contact-sync`, daily 07:30 — deliberately clear of the
02:00 Kopia run so it never writes mid-snapshot). Conflicts: newest
edit wins whole-contact; the losing version survives in the store's git
history. Safety rails: any provider showing >20% inbound changes aborts
the whole run before any write; any outbound plan >20% is skipped; each
run posts a per-provider in/out summary to Discord via Apprise
(warnings and aborts likewise).

**Incident, 2026-07-31 — two spokes failing daily, neither for the reason
the log gave.** Both surfaced in the same run summary and both had
misleading messages, which is the real lesson here: an error string that
names the wrong layer costs more time than no message at all.

*Google — `PULL FAILED (HTTP Error 400: Bad Request)`.* The 400 came from
the **OAuth token endpoint**, not the People API — no contact call ever
happened. The real body was `{"error": "invalid_grant",
"error_description": "Token has been expired or revoked."}`, which urllib
discards unless you explicitly read it.

**The actual 2026-07-31 root cause was a typo in a Pass field name, not
the token.** The `Contact Sync Google` item held **two** token fields — the
real `GOOGLE_REFRESH_TOKEN` and a misspelled `GOGOLE_REFRESH_TOKEN` — and
two separate freshly-minted tokens were both pasted into the misspelled
one. The code read the correctly-spelled field, got the stale value, and
Google truthfully reported "Token has been expired or revoked" about a
credential nobody was looking at. Every layer was telling the truth; the
combination was still deeply misleading, and two good tokens got blamed
before the item's field list was actually inspected.

*Check the field list before theorising about a credential.* Pass items
can hold fields in two places (`Custom.sections` and `extra_fields`), a
misspelled duplicate is invisible in the UI, and it silently shadows the
real value.

Both readers now **fail loudly with near-miss detection** — a missing field
exits non-zero and names the similar fields that do exist (`difflib`,
cutoff 0.6, which catches `GOGOLE`/`GOOGLE`), rather than the old
behaviour of printing nothing and exiting 0 so the caller silently
received an empty credential. An empty-but-present field is an error too.
`get_google_refresh_token.py` additionally **verifies the token it just
minted** with a real refresh round-trip before printing it, so a token that
reaches you is known-good and any later failure is a storage or naming
problem rather than an auth one.

**Re-authorising: `contact-sync/get_google_refresh_token.py`.** The Google
credential is an OAuth **Desktop app** client, which authenticates via a
**loopback redirect** (`http://127.0.0.1:<port>`, any port, nothing to
register). Google's OAuth Playground **cannot** be used with it — it fails
with `Error 400: redirect_uri_mismatch`, and no setting changes that. That
dead end was walked into on 2026-07-31 because the original loopback flow
had been run ad-hoc in July 2026 and never committed, so the method had to
be rediscovered under pressure. It is now a committed script: run it, sign
in, copy the printed token into the `GOOGLE_REFRESH_TOKEN` field of the
`Contact Sync Google` Pass item. It deliberately does **not** write to Pass
itself — the agent's Pass token is read-only, and a credential of this
sensitivity belongs in by hand. *Any ad-hoc procedure that mints a
credential should be committed at the time; the cost of not doing so is
paid later, in the middle of an outage.* The likeliest cause is the OAuth
app sitting in **"Testing"** publishing status, where Google expires
refresh tokens after **7 days** (last success 25 July, failing since 27
July, 12 consecutive runs). `spoke_google.access_token()` now reads the
error body and says so plainly, including the fix. **This class of failure
never self-heals** — it needs interactive re-authorisation, and if the app
stays in Testing it will recur every week.

*ms_work — the 200-result cap, and advice that could not work.* The
Thunderbird extension's `searchContacts` is the ONLY bulk-enumeration path
(no `listContacts`, no address-book filter — confirmed against
`tools/list`), and it caps at 200 results. `search_all()` detected the
truncation correctly but told you to "raise `max_results`", which does
nothing: the cap is server-side. Measured directly —

| requested | returned | `hasMore` |
|---|---|---|
| 50 | 50 | true |
| 199 | 199 | true |
| 201 | **200** | true |
| 1000 | **200** | true |

— and stated in the tool's own schema (`default 50, max 200`). Once the
library crossed 200 contacts this stopped being intermittent: the pull
failed **every** run where Thunderbird was up.

`search_all()` now **partitions the search space** instead — one query per
letter/digit prefix, recursively extending any prefix that still comes
back truncated, deduplicated by contact id, with the empty-query result
kept as a free extra seed for anything with neither name nor email to
match on. Verified live: **674 contacts in 2.0s**, against the 200 ceiling
it was stuck at. If a partition is still truncated at 4 characters deep it
**raises rather than returning a partial list** — a short list would look
to the sync engine like mass upstream *deletions*, which is far worse than
a failed run.

*Thunderbird simply being closed is now a soft skip.* The job runs at
07:30 whether or not the app is open, so that case reports as `ℹ️ skipped`
and no longer colours the run as a warning. Deliberately narrow — it
catches **only** `ThunderbirdUnavailable` (can't reach the extension at
all). Anything the extension rejects, and any enumeration failure, is
still a real, warning-level failure. The risk of soft-skipping is masking
genuine faults, and that boundary is where it's held.

**Dry run — `contact-sync/run-sync.sh --dry-run`.** Pulls every provider
and reports exactly what *would* change, writing nothing: no provider
writes, no `canonical.json`/`state.json` update, no vcard regeneration, no
git commit/push, no Apprise notification. Use it before any run you're
unsure about — after a spoke has been broken for a while, after editing
merge logic, or when a large change is plausible.

Writes are **redirected into a scratch directory**, not merely skipped.
That matters: the outbound spokes' `make_plan()` reads canonical **from
disk**, so without writing the inbound fold somewhere the reported plans
would be computed against a stale file and the numbers would be fiction.
The scratch directory is removed at the end.

Two deliberate exceptions, both correct rather than leaks:
- **The MS refresh-token cache still updates.** Microsoft rotates the
  refresh token server-side as a side effect of authenticating — that has
  already happened by the time the run sees it, so discarding the new
  token would leave a dead one cached and break the next *real* run.
- **`.pull-<provider>.json` files** are still written into `~/contact-sync`
  (they're the raw pull, rewritten every run either way).

Run it via `run-sync.sh` rather than calling `sync.py` directly, so the
credentials come through the identical Pass path as the scheduled job —
otherwise you're testing a different thing from the one that runs at 07:30.

**Recovery:** restore a provider from `~/contact-sync/snapshots/` (or
any Kopia snapshot of `~/contact-sync`) by replaying it through the
relevant spoke's plan/apply; the store's git history on Forgejo shows
exactly what changed in every run.

---

## Wanderer (https://wanderer.mathewcsims.uk) — runs on the Mac

[Wanderer](https://github.com/open-wanderer/wanderer) — self-hosted GPS
trail/ride log (elevation, distance, photos, tags per trail). Chosen for
cycle-ride logging over Dawarich (a general location-history tracker,
heavier 4-container stack) specifically because it's built for per-ride
entries rather than continuous location history, and its deployment is
lighter (SQLite via a bundled PocketBase image, not a separate Postgres).
Upstream calls its own KML import "experimental", but confirmed working
directly in real use (2026-07-28) — KML rides import natively with no
conversion step needed in practice, despite the label.

**Security review before deploying** (read the actual GitHub Security
Advisories, not just docs):
- **GHSA-9qg7-jr2x-prvh** — unauthenticated IDOR: private trails/comments
  were readable via the ActivityPub endpoints with no auth at all.
- **GHSA-7vqq-mjjr-h9j5** — unauthenticated SSRF (CVSS 10.0) in the
  `/api/v1/trail/download` endpoint.
- **GHSA-hx3v-rv4v-w875** / **GHSA-m7v2-6gj3-3g2p** — stored XSS via
  waypoint name/icon fields.
- All four fixed by **v0.20.0** (confirmed via commit/PR history — GitHub's
  own advisory API left `patched_versions` null for all four, not something
  to skip verifying). Images pinned by digest, not just the tag, since tags
  on Docker Hub aren't immutable.
- **Federation**: Wanderer bakes in ActivityPub with no env var to disable
  user-level AP endpoints at all (confirmed live — no
  `FEDERATION_ENABLED`/`DISABLE_FEDERATION` toggle exists anywhere in the
  codebase). Instance-to-instance federation is opt-in only — an admin has
  to manually discover+approve a peer via `/federation/` — so nothing
  federates outward unless that admin UI is deliberately used. Trails
  default to **private**, so residual exposure is limited to trails
  deliberately marked public, same as any other visibility toggle.
- **The first-registrant-becomes-admin race**: `PUBLIC_DISABLE_SIGNUP`
  defaults to `"false"` (signup open) in upstream's own reference compose —
  same risk class as HealthLog's initial setup, handled the same way: a
  **temporary Caddy IP-allowlist** (home public IP + `10.0.1.0/24` LAN
  range — both needed, since NextDNS's split-DNS rewrite sends home devices
  straight to the Pi's LAN IP, so Caddy sees a private address for local
  requests) blocked everyone else until the one real account was
  registered — confirmed directly against `data/pb_data/data.db` (exactly
  one row in `users`, not just trusted from the UI) — then
  `PUBLIC_DISABLE_SIGNUP` was set to `"true"` and redeployed, and the
  allowlist was removed from the Caddyfile.
- **`PUBLIC_DISABLE_SIGNUP` alone does NOT lock down registration** — a
  real finding, not a formality. Reading the actual source
  (`web/src/hooks.server.ts`, `routes/api/v1/user/+server.ts`) shows the
  env var only gates the SvelteKit frontend/wrapper route. The underlying
  PocketBase `users` collection ships with `createRule: ""` (empty string
  = open to anyone, confirmed via direct SQLite read of `_collections`)
  in every migration through v0.20.0, never touched by this env var, any
  hook, or any migration. A direct `POST` to PocketBase's own
  `/api/collections/users/records` would create a real account regardless
  of the setting — not reachable from the host or internet in this
  deployment (`db` publishes no port at all, only `web` does), but fixed
  properly anyway: authenticated as a PocketBase superuser (created via
  `pocketbase superuser upsert` inside the `db` container — no shell in
  that image, but the binary itself is directly `exec`-able) and PATCHed
  `createRule` to `null` (superuser-only) via PocketBase's own admin API,
  reached through `web`'s container (which has `curl` and network access
  to `db:8090` internally — no new port needed). Verified live: a direct
  POST afterward returns `403 Only superusers can perform this action`.
  This fix lives in `data/pb_data` (the persistent volume), so it survives
  redeploys — but a full `pb_data` wipe/reset would silently reopen it, so
  re-verify after any such reset. Superuser credentials
  (`admin@wanderer.local`, dashboard at `/_/`) live in the "Wanderer"
  Proton Pass item alongside the app secrets.
- **Container hardening**: `no-new-privileges:true` and `mem_limit: 512m`
  on all three containers (search/db/web), general defense-in-depth rather
  than a response to any specific found issue.
- **Upload endpoint** protected by `UPLOAD_USER`/`UPLOAD_PASSWORD` basic
  auth — cheap defense-in-depth on a public host, same reasoning as every
  other app's auth-endpoint hardening in this repo.

**Architecture**: three containers — `search` (Meilisearch, required by
the app for search, not optional), `db` (PocketBase/SQLite, bundled in the
`flomp/wanderer-db` image), `web` (the actual app). Only `web` is published
(bound to the Mac's real LAN IP, same podman-machine quirk as every other
Mac app here — podman-machine can't bind `0.0.0.0` to the real interface);
`search` and `db` are internal-only, reached by container name.

**Secrets** (`MEILI_MASTER_KEY`, `POCKETBASE_ENCRYPTION_KEY` — must stay
fixed forever once real data exists, rotating it breaks decryption of
existing records — `UPLOAD_USER`, `UPLOAD_PASSWORD`): the "Wanderer" Proton
Pass item, created via `scripts/pass-create-wanderer-secrets.sh` — run
under Mathew's own pass-cli session, not the agent's (agent PATs are
read-only by design).

**To bring it up on a fresh machine:**
1. **Mac:** `./scripts/pass-create-wanderer-secrets.sh` (once, if the Pass
   item doesn't already exist), then
   `./scripts/pass-deploy.sh wanderer Wanderer` — starts on `10.0.1.14:3400`.
2. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
3. **DNS:** `./scripts/dns-digitalocean.sh add wanderer <Pi's public IP>`
   and `./scripts/dns-nextdns.sh add wanderer.mathewcsims.uk 10.0.1.19`.
4. **First run only:** register the one real account immediately (the
   IP-allowlist is protecting this window), verify via
   `sqlite3 -readonly wanderer/data/pb_data/data.db "SELECT * FROM users;"`
   (exactly one row, not the UI's word for it), then set
   `PUBLIC_DISABLE_SIGNUP: "true"` in `wanderer/compose.yaml`, redeploy,
   and only then remove the setup-time IP-allowlist from the Caddyfile.
5. **Also first run only:** lock down the PocketBase `users` collection's
   `createRule` — `PUBLIC_DISABLE_SIGNUP` alone doesn't do this (see the
   security section above for why). Create a superuser
   (`podman exec wanderer-db /pocketbase superuser upsert <email>
   <password> --dir=/pb_data`), authenticate against
   `http://db:8090/api/collections/_superusers/auth-with-password` from
   inside the `web` container (it has `curl` and reaches `db` internally),
   then `PATCH http://db:8090/api/collections/users` with
   `{"createRule": null}` using the returned token. Verify with a direct
   `POST` to `/api/collections/users/records` — should return
   `403 Only superusers can perform this action`.
6. **Importing rides:** KML imports directly through Wanderer's own UI —
   confirmed working in real use, despite upstream's own "experimental"
   label on that import path.

### Wanderer -> Owl relay (`wanderer/memo-relay/`)

On every new trail Wanderer creates, posts a Memo to Owl (the personal
Memos instance, `owl.mathewcsims.uk`) with the ride's stats and a link back
to it. Wanderer has **no webhook system at all** — confirmed by reading its
actual source (both the SvelteKit frontend and the Go/PocketBase backend) —
so this uses PocketBase's own built-in realtime API instead: a persistent
Server-Sent Events connection to `/api/realtime` on the `db` container
(never reachable through `web` or Caddy — internal to the compose project
only), subscribed to the `trails` collection, reacting to `action: create`
events.

**Why superuser auth, not a scoped token**: trails default to private
(`viewRule: id = @request.auth.id`), and only the superuser account can see
every trail's realtime events regardless of owner — same pragmatic
tradeoff Karakeep makes using its full `MEILI_MASTER_KEY` rather than a
scoped index key elsewhere in this repo.

**Best-effort, no retry queue** — same pattern as
`vikunja-webhook-relay`'s Apprise forward: a failed Owl post is logged, not
retried. If this container is down when a ride is created, that event is
simply missed. Acceptable for a personal convenience feature.

**Data flow verified**: trail schema confirmed directly against the live
instance (`distance` in metres, `duration` in seconds, `elevation_gain`/
`elevation_loss` in metres — not guessed from docs).

**Three real bugs found and fixed after the first live test**, none
guessable from docs alone:
- **No title on the posted Memo.** Memos has no separate title field — a
  memo's displayed title is derived from a leading Markdown heading. The
  original first line was bold text (`**name**`), which Owl's frontend
  doesn't treat as a title at all. Fixed by leading with a real `# `
  heading.
- **`duration` reads as 0 for KML-sourced trails specifically.** Confirmed
  as a genuine upstream Wanderer bug, not a timing issue on this side:
  its KML->GPX conversion (`web/src/lib/util/gpx_util.ts`) parses
  per-point timestamps out of the KML but discards them before building
  GPX points, so the Go backend's duration computation
  (`MovingData()` from track-point timestamp deltas) gets none to work
  with and permanently stores 0 — computed synchronously at trail
  creation, not fixed by waiting longer. GPX imports are unaffected.
  Shown as "n/a" rather than a false "0m". Worth reporting upstream if
  this keeps mattering.
- **Wrong trail URL format.** Not `/trail/{id}` — the real viewer route is
  `/trail/view/@{username}@{host}/{id}`, an ActivityPub-style actor handle
  embedded in the URL. `{username}` is the app account's own username
  (`mathewcsims`), confirmed different from the login email's local part
  (`mat`) — read directly from the `users` table, not assumed.
- **Memos itself fails to linkify the correct URL.** Fixed the URL format
  above, then found a second, separate bug: even with the exactly correct
  URL as a bare string, Memos' own bare-URL auto-linkifier chokes on the
  `@user@host` segment in the path and never recognizes it as a link at
  all — confirmed via Memos' own API, `property.hasLink: false` on the
  posted memo despite the raw text being byte-for-byte correct. Fixed by
  posting the link as an explicit Markdown `[text](url)` link instead of
  a bare URL — bypasses the bare-URL heuristic entirely, parsed as a real
  link node regardless of what's in the URL's own path. Verified live:
  `hasLink: true` after the fix, both on new posts and on the one
  already-posted memo (patched in place via `PATCH .../memos/{id}
  ?updateMask=content`).
- **Posting can't be a fixed delay after `create` at all.** First fix was
  a flat 20s wait, which turned out to be the wrong shape of fix entirely
  — a human manually reviewing/editing a freshly imported trail (fixing
  the name, adding photos, correcting stats) can take far longer than any
  sensible fixed wait, and firing partway through an edit posts a
  half-finished entry. Replaced with a real debouncer: every `create` OR
  `update` event for a trail resets a per-trail timer
  (`DEBOUNCE_SECONDS`, default 15 minutes); the trail is only re-fetched
  and posted once it's gone quiet for that whole window, however long the
  actual editing session took. Each trail posts at most once per process
  lifetime.

**Photos/attachments**: the trail's `photos` field (a real PocketBase file
field, `maxSelect: 99`) — including Wanderer's own auto-generated
route-map image, which lives in the same field as real uploaded photos
with nothing to distinguish them — are fetched from `/api/files/trails/
{id}/{filename}` on `db` (superuser-authenticated) and attached to the
Memo via Owl's `POST /api/v1/attachments` (`memo` field set to the newly
created memo's `name`, linking it directly rather than a separate
`SetMemoAttachments` call).

**Secrets** (`WANDERER_SUPERUSER_EMAIL`, `WANDERER_SUPERUSER_PASSWORD`,
`MEMOS_TOKEN` — an Owl Personal Access Token): added to the existing
"Wanderer" Proton Pass item via
`scripts/pass-add-wanderer-memo-relay-secret.sh` — run under Mathew's own
pass-cli session. The Memos PAT is created first in Owl's own UI
(Settings -> Access Tokens), never handled by the agent.

**To bring it up**: `./scripts/pass-add-wanderer-memo-relay-secret.sh`
once, then redeploy the whole `wanderer` compose project
(`./scripts/pass-deploy.sh wanderer Wanderer`) — the relay is a fourth
service in the same compose file, so this brings it up alongside the app.
Note: `podman compose up -d` does NOT rebuild an already-built image just
because its source changed — after editing `relay.py`, run
`podman compose build memo-relay` in `wanderer/` first, then redeploy, or
the container keeps running stale code silently.

---

### A real bug found in shared Pass tooling while wiring this up

`pass-cli item update --field x=y` (used by `pass-add-*-secret.sh`
scripts to add secrets to an item after its initial creation) writes new
fields into a separate top-level `extra_fields` array, not into any
section — confirmed live by reading the raw `item view --output json`
response. Every `pass-deploy*.sh` / `dns-*.sh` / `mirror-backup-to-
external-drive.sh` script that reads secrets only looked at
`content.content.Custom.sections`, so any field added via `item update`
was silently invisible at deploy time — the CLI reports success
(`"N field(s) updated"` or `"created"`), the field is genuinely there and
readable via `item view`, it just wasn't where any deploy script looked.
Fixed in all affected scripts (`pass-deploy.sh`, `pass-deploy-remote.sh`,
`pass-deploy-kopia-server.sh`, `pass-deploy-timetagger.sh`,
`dns-digitalocean.sh`, `dns-nextdns.sh`,
`mirror-backup-to-external-drive.sh`) to also read `extra_fields` and
merge it in. `pass-seed-apprise.sh` already did this correctly. Worth
knowing for any future `pass-add-*-secret.sh` script: fields land in
`extra_fields`, and any NEW script reading Pass items needs to account
for this too.

---

## Immich (https://immich.mathewcsims.uk) — LAN/tailnet-only, runs on slartibartfast

Self-hosted photo/video library. **The first app in this repo on a third
host** — `slartibartfast`, an Ubuntu 26.04 box (LAN `10.0.1.11`, tailnet
`100.68.10.65`, SSH user `mathewcsims`) — chosen because the photo library
and its CPU-bound ML work don't belong on either existing machine.

The draw is Immich's AI: CLIP-based semantic search ("dog on a beach") and
face detection/clustering, both of which run locally with no third-party
service involved.

**Hostname is `immich.`, not `photos.`** — deliberately reserving
`photos.mathewcsims.uk` for a possible future *public* gallery-sharing tool,
which would need the opposite exposure posture to this LAN/tailnet-gated
instance.

### Hardware reality — measured, and it drives every AI decision

The box is an Intel i5-4590T (Haswell, 4c/4t @2.0GHz, 35W), 7.1 GiB RAM,
Intel HD 4600 iGPU, 238 GB SSD. Three consequences, each checked against
Immich's own docs rather than assumed:

- **ML runs on CPU — no OpenVINO.** Immich's OpenVINO backend targets
  "Iris Xe and Arc" (Gen 12+/discrete). HD 4600 is Gen 7.5, roughly six
  generations older, and the docs warn that older iGPUs and low-RAM servers
  are the likely failure cases *and* that OpenVINO increases RAM use. On
  7.1 GiB that's a clearly bad trade, so the plain CPU image tag is used.
- **Transcoding DOES accelerate, partially.** `/dev/dri` is passed through
  for Quick Sync H.264 **encode**. Haswell predates HEVC encode, and Immich
  hardware-accelerates only encoding (decode stays on CPU), so iPhone HEVC
  video means CPU decode + QSV H.264 encode — fine as a background job,
  slow for 4K. This is the hardware's weakest point.
- **RAM is the binding constraint**, which is why `immich/compose.yaml` sets
  a `mem_limit` on every service: they're the guardrail stopping the ML
  container from OOM-killing Postgres. Immich's own CLIP model guidance
  spans ~900 MiB to 6,500+ MiB — the large multilingual models simply don't
  fit here, so it stays on the default fast model.

The box shipped as Ubuntu **Desktop**; GNOME was costing ~1 GiB at idle, so
it's set to boot headless (`systemctl set-default multi-user.target`) to
give that RAM to ML. One command to reverse if a desktop is ever wanted.

### Networking — why this needed a new Caddy env var

Pi-resident apps are proxied by *container name* over the `pi-shared` docker
network. That cannot work across hosts, so Immich follows the **Mac**
pattern instead: publish a port, proxy by IP. The Caddyfile previously only
knew `{$MAC_IP}`, so this added `{$SLARTI_IP}` — wired through
`pi-reverse-proxy/compose.yaml`'s `environment:` block and the Pi's
(gitignored) `.env`, exactly the same shape, not a new mechanism. A fourth
host would add a third such var.

The port is bound to `10.0.1.11:2283` specifically rather than `0.0.0.0` —
Caddy is the only thing that should reach it, including for tailnet clients
(who go through the hostname like everyone else).

### Gotcha that cost the most time: Tailscale `--accept-routes` broke all LAN ingress

Immich deployed fine and answered on `http://10.0.1.11:2283` locally, but
Caddy returned **502** and the Pi could not reach the box *at all* — not
port 2283, not SSH, not even `ping` — while ARP resolved correctly and no
firewall was active anywhere.

Cause: **babel advertises `10.0.1.0/24` as a Tailscale subnet route** (so
remote tailnet clients can reach LAN services), and slartibartfast had
`--accept-routes` **enabled**. So it installed a route for its own local
subnet pointing at `tailscale0`, in Tailscale's routing table 52 — which
`ip rule` consults at priority 5270, *ahead of* `main` (32766). The
tell-tale:

```console
$ ip route get 10.0.1.19          # a host on the SAME physical LAN
10.0.1.19 dev tailscale0 table 52 src 100.68.10.65   # ← wrong
$ ip route get 1.1.1.1            # genuinely remote, correctly via eno1
1.1.1.1 via 10.0.1.1 dev eno1 src 10.0.1.11
```

That produced a confusing **asymmetry**: outbound LAN connections appeared
to work (they were quietly tunnelling out via babel and back), while
anything *inbound* died, because the reply to a packet received on `eno1`
was routed back through the tunnel and discarded as a mismatched return
path.

Fix, on the affected box:

```sh
sudo tailscale set --accept-routes=false
```

Safe and narrow: table 52's other entries are per-peer `/32` routes, which
`--accept-routes` doesn't govern, so tailnet connectivity (including
Tailscale SSH) is untouched. Immediately after, `ip route get 10.0.1.19`
returns `dev eno1` and ping latency drops to ~0.3 ms — genuinely local.

**Two lessons worth keeping.** First, this had nothing to do with Immich,
Docker, or a firewall — plain `ping` between those two hosts was already
broken before Immich existed, so it was a latent misconfiguration this
deployment merely exposed. Any future host added to both the LAN *and* the
tailnet needs `--accept-routes=false` if it sits inside an advertised
subnet. Second, `systemctl is-active ufw` reporting **active** while
`ufw status` says **inactive** is a genuine trap: the unit having run is not
the same as the firewall being enabled. Check `ufw status`, not the unit.

### Security posture

Immich's advisory history is substantial and worth reading before exposing
it anywhere: a **critical** one-click account takeover via XSS in the login
continue-redirect, API-key privilege escalation, stored XSS via OCR text in
the panorama viewer, account hijacking via oauth2, plus a cluster of five
published 2026-07-06 covering OIDC TLS verification, shared-link
authorisation and open redirects. **Every published advisory is patched by
v3.0.0**; the pinned v3.1.0 clears all of them.

Note *where* those bugs cluster: OAuth/OIDC and public shared-link code
paths. Two deliberate choices avoid most of that surface —
**local accounts only** (no Infomaniak SSO, unlike Owl/Marque/TimeTagger)
and **no public sharing**. Friends who want access get tailnet access
instead of this being opened to the internet.

Registration must be closed once the one real account exists — the same
first-registrant-becomes-admin race as HealthLog and Wanderer.

### AI configuration (Admin ▸ Settings)

- Enable **Smart Search** and **Facial Recognition**.
- Keep the **default CLIP model** — see the RAM note above.
- **Turn job concurrency DOWN** (1–2) for Smart Search, Face Detection and
  Transcoding. On 4 slow cores with a tight RAM budget the defaults will
  thrash; this is the single most important tuning knob on this hardware and
  most guides skip it entirely.
- Set the external domain to `https://immich.mathewcsims.uk` — it bakes into
  share links and emails, the same class of gotcha as `MEMOS_INSTANCE_URL`.
- Gradual import is an advantage here: ML work spreads out instead of
  becoming a multi-day first pass.

### Backups — the important part

This is the most irreplaceable data in the stack, and **Immich is not itself
a backup**.

- **Immich's own DB backup is enabled** (Admin ▸ Settings ▸ Backup — daily
  02:00, 14 retained), writing dumps to `data/backups/`. Upstream is
  explicit that a file-copy of a live Postgres datadir will not reliably
  restore, which is why `pgdata/` is deliberately *excluded* from backup and
  the dump is what gets kept.
- **Kopia runs as a third client** on slartibartfast, connecting directly to
  the same B2 repository as the Mac and Pi (with
  `--override-hostname=slartibartfast` so its snapshots are identifiable).
  It is deliberately **not** maintenance owner — the Pi holds that, being
  always-on.
- Snapshots cover `data/library/`, `data/upload/`, `data/profile/` and
  `data/backups/`. `data/thumbs/` and `data/encoded-video/` are **excluded**
  — regenerable per upstream, and excluding them saves real B2 cost. The
  trade-off: regeneration on this CPU is slow, so a full recovery takes
  longer in exchange for cheaper ongoing storage.
- Scheduled at **03:00 via a systemd timer** (`immich/kopia-immich.timer` +
  `.service`, installed to `~/.config/systemd/user/`) — deliberately after
  Immich's 02:00 dump so every snapshot contains a fresh one. Moving it
  earlier would snapshot a stale dump. Follows the existing
  `pi-unattended-upgrades/reboot-check.timer` shape (`OnCalendar` +
  `RandomizedDelaySec=15m` + `Persistent=true`).
- Runs as a **`--user` unit, not a system one**, so no root is involved:
  `loginctl enable-linger mathewcsims` (which doesn't need sudo) makes it
  fire without an active login. This works only because Immich's
  container-written directories are root-owned but **world-readable** — a
  real dependency, so `kopia-backup.sh` checks each snapshot's exit status
  and fires an Apprise alert on failure rather than reporting a cheerful
  success. A silently-partial backup of the photo library would be worse
  than an obviously-broken one.
- **Kopia's password is persisted to a file, not a keyring**, on this box:
  `~/.config/kopia/repository.config.kopia-password` (0600). That's Kopia's
  own fallback when no keyring daemon is available, which is the normal case
  on a headless server — and it's what lets the timer run unattended without
  the password being supplied.
- Verified working, not assumed: a manual
  `systemctl --user start kopia-immich.service` produced all four snapshots,
  visible from **both** the slartibartfast client and the Pi's — confirming
  they really do land in the shared repository.

**Wider gap found while building this, NOT specific to Immich:** every other
database in this repo — HealthLog's Postgres, Ghost's MySQL, BookStack's
MariaDB, Nimbus's Postgres — is backed up as a **live, un-quiesced data
directory** with no dump step anywhere (confirmed: zero `pg_dump`/
`mysqldump` calls in the repo). That is a real restore risk and deserves
separate work. Immich avoids inheriting it only because it ships its own
dump mechanism.

### Deploy

Two steps, same as Pi apps — the deploy script does **not** copy the folder:

```sh
scp -r immich mathewcsims@100.68.10.65:~/immich
./scripts/pass-deploy-remote.sh immich mathewcsims@100.68.10.65 '~/immich'
```

Secrets (`DB_PASSWORD`) come from the "Immich" Pass item, created once by
`scripts/pass-create-immich-secrets.sh` under your own pass-cli session
(agent PATs are read-only). The item title must stay exactly `Immich` — the
deploy script derives it from the app-dir name.

**Gotchas:**
- `pass-deploy-remote.sh` runs a bare `up -d` with **no `pull`**, so a
  version bump has to be a deliberate digest edit in `compose.yaml`. That's
  protective given Immich ships breaking changes regularly — read the
  release notes before bumping.
- Immich's Postgres image is **its own** (`ghcr.io/immich-app/postgres`,
  carrying VectorChord + pgvecto.rs). Substituting stock Postgres breaks
  smart search outright, so it deliberately does not match HealthLog's
  `postgres:16-alpine`.
- `cap_drop: ALL` is deliberately **not** copied from `msims-link` here —
  Immich's Postgres needs chown/setuid/setgid at startup and the server
  shells out to ffmpeg. `no-new-privileges` is applied throughout instead.
- `DB_PASSWORD` is baked into the Postgres cluster on first `up`. Changing
  it in Pass later won't change the database's actual password — that needs
  an `ALTER USER` inside the running DB too.
- Ubuntu's `docker.io` package does **not** include Compose v2 — that's a
  separate `docker-compose-v2` install (available in Ubuntu's universe
  repo, so Docker's own apt repo isn't needed).

---

## LiteLLM (https://litellm.possum-prometheus.ts.net) — TAILNET-ONLY, runs on slartibartfast

An OpenAI-compatible proxy in front of **employer-funded Gemini Enterprise
Agent Platform** — the product Google renamed from "Vertex AI" on
2026-04-22 — so every device gets one stable endpoint and one key format
instead of each app needing GCP SDKs and credentials of its own. Added
2026-08-02.

**Naming:** prose uses the current product name. The `VERTEXAI_*` env vars,
the `vertex_ai/` model prefixes in `config.yaml` and the
`aiplatform.googleapis.com` host are **literal identifiers** that LiteLLM and
Google both still use — the rebrand did not change the API surface, so they
must not be "corrected".

### Why slartibartfast, and not the Mac or the Pi

- **The Pi is at 85% disk** (4.2 GB free on a 29 GB card). No room for
  another image plus a Postgres volume.
- **The Mac does not come back by itself after a power cut.** Proven twice
  on the day this was built: the podman VM stayed down until restarted by
  hand, taking all 13 Mac-hosted apps with it. This needs to answer a phone
  without someone at a keyboard.
- **slartibartfast** has 169 GB free, ~5.5 GB RAM available, four containers,
  load 0.14 — and is x86_64, LiteLLM's primary build target. The third-host
  Caddy plumbing (`{$SLARTI_IP}`) already exists from Immich.

### Exposure: published on the tailnet by a sidecar, NOT through Caddy

This app has **no public hostname, no DNS record and no published port**. A
`tailscale` sidecar joins the tailnet as `litellm` and proxies to the app
over the compose network, so the only address is
`https://litellm.possum-prometheus.ts.net` and the only route in is the
tailnet itself — there is no non-tailnet path even from this house.

**Caddy was tried first and could not do this. Do not reinstate it.**
Gating with `remote_ip 100.64.0.0/10` (CGNAT only, no `private_ranges`)
adapted cleanly and validated fine, but aborted every request from the Mac
while working from the Pi. Diagnosed live rather than guessed: over the
*identical* tailnet path, `immich.mathewcsims.uk` — which also matches
`private_ranges` — returned 200 while this one aborted, while a request from
the Pi's *own* tailnet address passed the CGNAT matcher fine. The most likely
reading is that Caddy does not see the client's 100.x address for tailnet
traffic arriving at the containerised proxy. **That is an inference, not a
measurement** — repeated attempts to capture the actual `remote_ip` for such
a request from the access log failed. What is certain is only the outcome:
CGNAT-only matching did not work here.

**This does NOT weaken the other apps' gates**, and an earlier draft of this
section wrongly implied it did. The `private_ranges 100.64.0.0/10` gates on
BookStack, Forgejo, Apprise, Kopia and Immich exist to admit LAN and tailnet
while denying the internet, and they still do exactly that:

- internet traffic arrives with a public source IP and is aborted — router
  NAT rewrites the *destination*, not the source;
- a private source cannot be spoofed from outside, because the request must
  complete both a TCP and a TLS handshake before Caddy evaluates anything;
- other LAN devices can reach those apps, but `private_ranges` admits them
  **by design** — that is not a consequence of anything found here.

The only real implication is narrower: the `100.64.0.0/10` clause in those
matchers may be **redundant**, since `private_ranges` would already cover
whatever Caddy sees. Do not act on that without measuring first — it may be
doing genuine work for a device on the tailnet but *not* on the LAN, such as
a phone on mobile data.

One documentation point does follow. The 2026-07-23 ACL entry describes those
gates as relying on "trusting the tailnet CGNAT range as personal only". If
tailnet traffic does not present as CGNAT, that framing is inaccurate: they
are really "LAN **or** tailnet", with LAN the broader admission. An accuracy
correction, not an exposure.

The sidecar approach is stronger anyway: access is decided by tailnet policy
at the network layer, not by IP matching in a proxy.

### Access control: tag:personal, no ACL change needed

The sidecar's auth key stamps the node **`tag:personal`** at registration.
The existing tailnet grant already does exactly the right thing:

```
{"src": ["tag:personal"], "dst": ["*"], "ip": ["*"]}
```

Verified against the live policy and device list via the Tailscale API
before building: `heartofgold`, the Z Fold7, `Arthur`, `glkvm` and
`slartibartfast` all carry `tag:personal`; the **work Mac `SCMAC-NH2WF7` is
untagged and therefore has no grant at all**. No policy edit was required —
tagging the node was sufficient, as expected.

Consequence: **if Tailscale is down on a device, this app is unreachable
from it.** That is inherent to the posture, not a fault.

### Auth to GCP: ADC, not a service-account key

Employer policy blocks downloadable service-account keys, so this uses
**Application Default Credentials** created by an interactive
`gcloud auth application-default login` on slartibartfast. Consequences:

- The ADC file is a **user credential** (a refresh token for a real person),
  not a service account. It is mounted **read-only**, and is deliberately
  **not** in this repo and **not** in Pass — it stays on the host that
  created it.
- It can be revoked centrally at any time, and may expire under an org
  session-length policy. **If platform calls start returning 401, re-run the
  login** — that is not a LiteLLM fault and no amount of restarting fixes it.
- **A quota project could not be set, and it does not matter.** The ADC
  account lacks `serviceusage.services.use` on the project, so
  `set-quota-project` fails outright. Verified live that this is harmless:
  the platform puts the project in the request path, and a real
  `generateContent` call returned 200 without one. Do not chase this.

The Google Cloud CLI is installed **in userspace** at
`~/google-cloud-sdk` on slartibartfast (there is no passwordless sudo on
that host, and this needs none) — official tarball, nothing system-wide.

### What this project actually has — and how two sweeps got it wrong

**17 models are exposed.** Getting there took three passes, and the two
failures are worth more than the answer.

**The LIST APIs are unavailable to this credential.** They need a quota
project, and the ADC account lacks `serviceusage.services.use` to set one —
so the REST `/publishers/*/models` endpoints fail, and `gcloud ai
model-garden models list` falls back to Google's shared project
(`32555940559`, `SERVICE_DISABLED`) on the Mac too. Inference works fine;
only enumeration is blocked.

**Failure 1 — probing only one API surface.** The first sweep tested only
`/publishers/<pub>/models/<id>`. MaaS models (gpt-oss, qwen) are served from
`/endpoints/openapi/chat/completions` with **publisher-prefixed** names, a
different surface entirely. Missing it hid three models.

**Failure 2 — guessing stale model names.** The second sweep probed
`gemini-2.0-*`, `gemini-3-pro`, `claude-sonnet-4-5`, `claude-opus-4-1`. None
exist. The current generation is **Gemini 3.5/3.6 and Claude 5**, so every
probe 404'd and the sweep concluded "no Anthropic, Meta or Mistral access on
this project" — confidently, and completely wrongly. Claude Opus 5 and
Sonnet 5 were available the whole time.

**What actually resolved it: reading the Model Garden UI.** Each model page
shows a **Model ID** (`publishers/anthropic/models/claude-opus-5`) and a
**Version name** (`claude-opus-5@default`). That is ground truth. When the
list APIs are blocked, read the portal — do not extrapolate from model names
you think you know.

| Region | Models |
|---|---|
| **europe-west2** (London, UK) | `gemini-3.5-flash`, `gemini-2.5-flash`, and all four embedding models |
| **europe-west1** (Belgium, EU) | `gemini-2.5-pro`, `gemini-2.5-flash-lite`, `gemini-2.5-flash-image` |
| **global** (anywhere) | `claude-opus-5`, `claude-sonnet-5`, `gemini-3.6-flash`, `gemini-3.5-flash-lite`, `gemini-3-flash-preview`, `gpt-oss-120b`, `gpt-oss-20b`, `qwen3-next-80b` |

**Not available, and why:**

- **Mistral** (`mistral-medium-3` etc.) — visible in Model Garden but shows an
  **Enable** button, i.e. not yet enabled on this project. Click Enable in the
  portal, then re-probe; nothing here needs changing first.
- `claude-haiku-5`, `gemini-3.6-pro`, `gemini-3.5-pro`, `gemini-3.6-flash-lite`,
  `gemini-4-flash`, Llama, Imagen — 404 in every region tried.

**Re-probe rather than assume** whenever this is revisited: model generations
turn over fast, and `/tmp/probe*.py`-style scripts (a model × region matrix
hitting the right endpoint per family) take minutes.

### Data residency — deliberate, and visible at the point of use

`vertex_location` is set **explicitly per model** in `config.yaml` so the
region is never inherited silently:

- `europe-west2` (London) — UK. The project's default.
- `europe-west1` (Belgium) — EU, not UK.
- `global` — may be served from **any** region, including outside the EU/UK.

UK-resident models get the plainest names (`gemini-flash`,
`text-embedding`); anything leaving the UK is named for it
(`gemini-pro-eu`, `gemini-3-flash-preview-global`), so the trade-off is
visible when you pick a model rather than buried in config. Where a model
exists in several regions the closest/most-resident one was chosen —
`europe-west1` over `us-central1` in every case.

### Setup (the parts only you can do)

Both of these are yours, not the agent's: the first because pass-cli agent
PATs are read-only by design, the second because it authenticates as **you**
against your employer's Google account.

**1. Create the Pass item** (on the Mac):

```sh
./scripts/pass-create-litellm-secrets.sh
```

Generates `POSTGRES_PASSWORD`, `LITELLM_MASTER_KEY` and `LITELLM_SALT_KEY`
straight into a new "Litellm" item — none printed, none via argv. Then add
two more fields **by hand** to that same item, because they aren't secrets
and can't be generated:

- `VERTEXAI_PROJECT` — your GCP project ID (`gcloud config get-value project`)
- `VERTEXAI_LOCATION` — the region, e.g. `europe-west2` or `us-central1`
- `TS_AUTHKEY` — a Tailscale auth key **created with `tag:personal`**. That
  tag is what makes the existing grant apply; an untagged key would register
  the node with no tag and no grant. Reusable, so a container rebuild
  re-registers cleanly.

  A stray character on paste is the failure mode to expect here: the first
  attempt stored 62 characters against a 61-character key and tailscaled
  rejected it with `invalid key: unable to validate API key`, which reads
  like a permissions problem rather than a typo. Copy via `pbcopy <file` on
  **the Mac** rather than retyping.

**2. Create the ADC credential** (on slartibartfast, over SSH):

```sh
~/google-cloud-sdk/bin/gcloud auth application-default login --no-launch-browser
```

Headless-friendly: it prints a URL, you authenticate in a browser on any
device, and paste the code back. Then pin the quota project:

```sh
~/google-cloud-sdk/bin/gcloud auth application-default set-quota-project YOUR_PROJECT_ID
```

That writes `~/.config/gcloud/application_default_credentials.json`, which
compose mounts read-only at `/adc`.

### Deploy

Same two-step as Immich — the folder is **not** copied by the deploy script:

```sh
scp -r litellm mathewcsims@100.68.10.65:~/litellm
./scripts/pass-deploy-remote.sh litellm mathewcsims@100.68.10.65 '~/litellm'
```

Note `pass-deploy-remote.sh` runs a bare `up -d` with **no `pull`**, so a
version bump must be a deliberate digest change followed by an explicit
`docker compose pull` on the host.

### Connecting a client

Everything speaks to this as an **OpenAI-compatible** endpoint. Three things
to get right, and one of them bites almost every client.

**1. Endpoint — origin and path are usually SEPARATE fields.**

| | |
|---|---|
| Base URL / host | `https://litellm.possum-prometheus.ts.net` |
| Path (if asked separately) | `v1/chat/completions` |
| Combined, if one field | `https://litellm.possum-prometheus.ts.net/v1` |

**The trap: most clients CONCATENATE host + path.** Put the full endpoint URL
in the host field and you get
`…/v1/chat/completions/v1/chat/completions` and a 404. Hit live with Goose,
and the doubled path is visible right there in the error text:

```
Resource not found (404) at
https://litellm.possum-prometheus.ts.net/v1/chat/completions/v1/chat/completions
```

**A 404 with a repeated path is always this**, never a missing model or a bad
key. Check the host field before anything else.

**2. One virtual key per device — never the master key.**

`LITELLM_MASTER_KEY` is the admin credential that *mints* keys. It should
never leave Pass. Give each device its own virtual key so spend is
attributable and any one device can be revoked without disturbing the others
— this is the whole reason the deployment carries Postgres.

Mint one (from the Mac, on the tailnet):

```sh
curl -s -X POST https://litellm.possum-prometheus.ts.net/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"key_alias":"<device>-<tool>"}'
```

Use a descriptive alias (`goose-heartofgold`) — it is what you will be
reading later when deciding what to revoke. Existing keys:
`GET /key/info`; revoke with `POST /key/delete`.

**3. Model name must match `config.yaml`**, not the upstream Google ID.
Clients see `gemini-flash`, not `gemini-3.5-flash`. `GET /v1/models` lists
what is actually available. Remember the naming carries residency:
unsuffixed = UK, `-eu` = Belgium, `-global` = anywhere.

**Reachability.** The tailnet is the only route in. If a client cannot
connect at all — no TLS, no 401, nothing — check Tailscale is up on that
device before debugging anything else.

**Worked example — Goose (desktop), configured 2026-08-02.** In
`~/.config/goose/config.yaml`:

```yaml
providers:
  litellm:
    enabled: true
    model: gemini-flash
    configured: true
LITELLM_HOST: https://litellm.possum-prometheus.ts.net   # origin ONLY
LITELLM_BASE_PATH: v1/chat/completions
LITELLM_TIMEOUT: '600'
```

`LITELLM_API_KEY` lives in the **macOS keychain**, not the config file —
service `goose`, account `secrets`, as a JSON blob. Inspect it with
`security find-generic-password -s goose -a secrets -w`. Goose reads config
at launch, so **restart it after any change**.

### Audio transcription — use a chat model, not a speech model

**Non-obvious and worth knowing before reaching for a dedicated ASR model:
`gemini-flash` transcribes audio, through the normal
`/v1/chat/completions` endpoint, with no extra configuration.** Verified
2026-08-02 with a generated WAV — returned the sentence verbatim first
attempt.

Send the audio as an `input_audio` content part alongside the instruction:

```json
{"model": "gemini-flash",
 "messages": [{"role": "user", "content": [
   {"type": "text", "text": "Transcribe this audio verbatim."},
   {"type": "input_audio", "input_audio": {"data": "<base64>", "format": "wav"}}]}]}
```

It stays **UK-resident** (`gemini-flash` is pinned to `europe-west2`), which a
dedicated speech service would not necessarily be.

**Why not Chirp 2**, which is visible in Model Garden and looks like the
obvious choice — two independent blockers, both checked:

1. **It is not on the Vertex publisher surface.** `chirp-2:predict` returns
   404 in `europe-west2`, `us-central1` and `global`. Model Garden lists it,
   but it is not served from `aiplatform.googleapis.com` like the Gemini and
   Claude models.
2. **Its real API is disabled on this project.** Chirp is served by Cloud
   Speech-to-Text v2 (`speech.googleapis.com`), which returns *"Cloud
   Speech-to-Text API has not been used in project ... or it is disabled"*.
   A portal action, same shape as Mistral's Enable button.

Even with the API enabled, LiteLLM lists `vertex_ai` among its transcription
providers but documents nothing Chirp-specific, so whether it would route to
Chirp rather than Gemini audio is **unproven** — test it before relying on it.

**What Gemini does NOT give you**, and would justify enabling Chirp:
word-level timestamps, speaker diarisation, and streaming recognition. For
plain "turn this file into text", the chat model is sufficient and needs
nothing enabling.

### Credential expiry monitor (added 2026-08-06, after it bit)

**The ADC credential expires, silently, and nothing else notices.** It is a
*user* refresh token — service-account keys are org-blocked — so Google's
reauth policy kills it. Observed lifetime: **four days** (created 2026-08-02
14:02, dead by 2026-08-06 12:08).

The failure is nasty because **LiteLLM stays perfectly healthy**: the
container is up, `/health/liveliness` returns 200, the tailnet sidecar is
fine. Only the upstream credential is dead, so every completion 500s with
`RefreshError: Reauthentication is needed`. A conventional uptime check sees
nothing wrong. The first sign the first time was a stack trace in Goose.

`litellm/adc-check.sh` + `litellm-adc-check.{service,timer}` — a user systemd
timer on slartibartfast, same pattern as `kopia-immich.*`, every 30 minutes:

1. `gcloud auth application-default print-access-token` — exits non-zero the
   moment the refresh token needs reauthenticating. A precise leading
   indicator, and it needs no secrets.
2. Only if that passes, the unauthenticated liveliness endpoint — so an alert
   names one cause, not two.

Alerts go to Apprise → ntfy + Discord, on **state transition** plus a daily
re-nag while still broken (resend-only-on-change, same as the rest of the
estate). The ADC alert carries the exact reauth command, because that is
always the fix.

**Needs no LiteLLM API key at all** — the liveliness endpoint is
unauthenticated and the credential check runs as the credential's owner.
Nothing secret is read, stored or transmitted.

**Verified both paths, not just the happy one.** `GCLOUD` is overridable
precisely so the failure branch can be exercised without breaking the real
credential:

```sh
GCLOUD=/bin/false ~/litellm/adc-check.sh     # simulates an expired ADC
```

Delivery was confirmed end-to-end from slartibartfast — Apprise reported
`Sent ntfy notification` and `Sent Discord notification`. Note `notify()`
discards the response body, and Apprise reports per-service delivery *there*
rather than in its container log, so testing delivery means capturing the
response, not grepping `docker logs`.

`Linger=yes` is set for the user, so the timer runs without an active login
and survives reboots.

**The fix when it fires** (only Mathew can run it — it authenticates as his
Google account):

```sh
ssh mathewcsims@100.68.10.65 '~/google-cloud-sdk/bin/gcloud auth application-default login --no-launch-browser'
```

No restart needed; LiteLLM reads the credential per request.

**This monitors the symptom, not the cause.** The cause is that a long-running
workload is authenticating with a human's credential. The proper fix is
Workload Identity Federation — and the org policy permits it
(`constraints/iam.workloadIdentityPoolProviders` is `allValues: ALLOW`, and
the IAM permissions are present). What it needs is an OIDC issuer, which on a
home box means **self-hosting one**. Deliberately not built: allowed by
configuration is not the same as sanctioned by the employer, and it would
create a durable non-expiring path into their project secured by a key in a
spare room. Ask the platform team what they sanction for long-running
non-GCP workloads before building it.

### Gotchas

- **The Pass item must be titled exactly `Litellm`**, not `LiteLLM` — the
  deploy script derives the title from the app-dir name (kebab →
  PascalCase), so `litellm` resolves to `Litellm`. Prettifying it breaks the
  lookup silently.
- **`LITELLM_SALT_KEY` is set once and never rotated.** It encrypts provider
  credentials at rest in Postgres; changing it after models are stored makes
  every stored credential undecryptable, with no recovery short of wiping
  the database.
- **`LITELLM_MASTER_KEY` is not the key you put on a phone.** It is the
  admin key that *mints* per-device virtual keys. Treat it like a root
  password; issue a separate virtual key per device so one can be revoked
  without rotating everything.
- **`POSTGRES_PASSWORD` is baked into the data directory on first `up`.**
  Changing it in Pass later won't change the database's real password — that
  needs an `ALTER USER` inside the running DB too. Same trap as Immich and
  HealthLog.
- **Model IDs are not guaranteed.** Vertex model availability varies by
  project entitlement and region, and an unavailable model fails at **call**
  time, not at startup — so a healthy proxy can still 404 every request.
  Verify what the project actually has before relying on `config.yaml`'s
  list.
- **The app service is `app`, not `litellm`, and that matters.** The sidecar
  sets `hostname: litellm` to get the tailnet name — and that hostname
  **shadows** any container or service also called `litellm` in Docker's
  internal DNS. With both named `litellm`, the sidecar's serve proxy resolved
  the target to *itself* and returned 502 with "connection refused" on its
  own address. Hit live. Keep the names distinct.
- **`TS_ACCEPT_DNS` must be `false` on the sidecar.** With MagicDNS on,
  tailscaled rewrites the container's resolver and appends the tailnet search
  domain, so the serve target stops resolving as a Docker service name. The
  sidecar has no need to resolve tailnet names itself.
- **No Caddy, no DNS records.** Nothing to add to `pi-reverse-proxy/` and
  nothing in DigitalOcean or NextDNS. The `llm.mathewcsims.uk` A record and
  NextDNS rewrite created during the abandoned Caddy attempt were removed.

---

## Paperless-ngx (https://paperless.mathewcsims.uk) — LAN-only, runs on the Mac

Personal document store: official letters, medical documentation,
certificates, receipts. OCRs on ingest so scans become searchable. Deployed
2026-08-04. **Document blobs live on the NAS; the database and index do
not.** See `paperless/compose.yaml` — its header is the authoritative
explanation of that split and why it is not negotiable.

**This instance is deliberately not wired to LiteLLM.** That proxy fronts
the employer-funded Gemini Enterprise Agent Platform, and this store holds
personal medical and legal documents. The intended work document store is a
separate deployment on slartibartfast sharing nothing with this one. No AI
layer here yet at all — OCR plus full-text search answers most of what this
is for, and the decision is easier with real documents in it.

### The NAS mount: what does not work, and why

**A Finder mount plus a bind mount cannot work, and fails confusingly.**
podman-machine runs containers inside a libkrun VM that does not share
`/Volumes`, and an SMB mount made on the macOS side does not propagate
across virtiofs into the VM. Verified directly:

```
$ podman run --rm -v /Volumes/Public:/test:ro alpine:3 ls /test
Error: statfs /Volumes/Public: no such file or directory
```

So the mount is done by the VM's own kernel, via a compose volume with
`driver_opts: type=cifs`. Fedora CoreOS has `cifs.ko` and `mount.cifs`
already, and reaches `10.0.1.12:445` fine.

**The consequence for credentials is the non-obvious part.** Because the
Linux VM performs the mount, the Mac's Keychain is not reachable at the
moment it is needed. `NAS_USER`/`NAS_PASSWORD` therefore have to be fields
on the **"Paperless"** Pass item — not a convenience, the only way the mount
can authenticate. The Keychain copy still serves the Finder `/Volumes`
mounts and should stay; these are a second copy for a different consumer.

The NAS account is `paperless-user`, scoped to the `Paperless` share alone —
deliberately not `hog-user` (which also reaches magrathea, Archive, Public,
ProtonDriveBackup) and not `admin`. A credential that has to sit in a
container environment variable should be able to do as little as possible.

### Deploying

1. On Eddie: create the `Paperless` share and a dedicated account with
   read/write on it, and nothing else.
2. `./scripts/pass-create-paperless-secrets.sh` — run under your **own**
   pass-cli session; agent tokens are read-only and cannot create items. It
   generates the Django secret key and admin password, and prompts for the
   admin username/email and the NAS credentials.
3. `./scripts/pass-deploy.sh paperless`
4. DNS: `./scripts/dns-digitalocean.sh add paperless <WAN IP>` and the
   NextDNS rewrite to `10.0.1.19`, then deploy the Caddy block.

Paperless creates `media/`, `consume/` and the media subtree on the share
itself on first boot — no need to pre-create them.

### Things found the hard way

- **`mount error(13)` is a NAS-side permissions problem, not a client
  one.** First deploy failed here; the share existed and the account
  existed, but the grant was wrong. Diagnose by mounting inside the VM by
  hand with `-o credentials=<file>` before touching any mount option — that
  isolates authentication from option-string parsing. `sudo dmesg | grep
  -i cifs` in the VM gives the actual return code (`-13` = EACCES).
- **inotify does not work over CIFS.** With the consume directory on a
  share, no filesystem event ever fires and Paperless silently ingests
  nothing — it does not error. `PAPERLESS_CONSUMER_POLLING` is mandatory
  here, not tuning. The polling-retry settings exist because a file copied
  over SMB can be visible before it is fully written.
- **`PAPERLESS_FILENAME_FORMAT` needs double braces** (`{{ created_year }}`)
  on 3.x — Jinja templating. Single braces still work but warn on every
  startup check. Compose does not interpolate `{{ }}`, only `${ }`, so it
  passes through untouched.
- **3.x indexes with Tantivy, not Whoosh**, and runs SQLite in WAL mode —
  which is precisely why `db.sqlite3` is dumped by
  `scripts/dump-databases.sh` rather than merely snapshotted live.
- **Deleting a document soft-deletes it to a trash** with a 30-day delay.
  `hard_delete()` from the Django shell removes the database row but
  bypasses the file-cleanup signal, orphaning blobs on the share. Empty the
  trash through the UI instead.

### Getting email into Paperless

The email *body* is frequently the substantive content here, not just a
wrapper around an attachment, so both need to arrive — and to be readable
rather than merely searchable.

**The interface is the consume folder, not any particular application.**
That is the design, and it is worth stating plainly because it is what makes
every other decision below fall out the way it does. Anything that can write
to the NAS `Paperless/consume/` share is an ingestion source: a mail client,
a phone, a scanner, another machine, a script. Producers are swappable and
can be added on any device without touching this deployment at all.

**The current producer** is Thunderbird (already connected to Proton Mail
Bridge on the Mac) with two add-ons — **FiltaQuilla**, which adds
filesystem-writing actions to message filters, and **PrintingTools NG**,
which renders a message to PDF. A filter saves the message as a **PDF**,
and attachments separately, into the share. Paperless picks them up within
the polling interval and needs no conversion services at all.

Neither add-on nor the filter configuration is in this repo, so rebuilding
that Mac means re-installing both and recreating the filter by hand. That is
a chore rather than a hole: the ingestion *path* is the share, which is
backed up and reachable from anything, and the mail client is one
interchangeable front-end onto it. A different producer — or the same one on
a different machine — feeds the same folder with no changes here.

Two consequences worth exploiting:

- **`PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS` is already on.** Dropping into
  `consume/Scanner/` or `consume/Phone/` tags by source automatically,
  composing with the Inbox tag the workflow applies rather than conflicting
  with it.
- **The polling-retry settings earn their keep with more than one
  producer.** A file copied over SMB can be visible before it is fully
  written, which is a nicety with one source and real protection when a
  phone is pushing a large scan over wifi.

Two routes were tried first and rejected. Both are worth recording, because
the second looks obviously right and is not.

#### Why not save the messages as `.eml`

Because Paperless will not recognise them. It sniffs content with
**libmagic** rather than trusting the file extension, and Thunderbird
prepends its own headers to a saved message. Measured directly:

| File begins with | libmagic reports | Paperless routes to |
|------------------|------------------|---------------------|
| Standard `Subject:` / `From:` | `message/rfc822` | mail parser |
| `X-Mozilla-Status:` … | **`text/plain`** | text parser |
| mbox `From ` line | `application/mbox` | — |

So a Thunderbird-saved `.eml`, correctly named and perfectly valid, is
classified as plain text and never reaches the mail parser.

**`PAPERLESS_PRE_CONSUME_SCRIPT` cannot fix this**, which is the
counter-intuitive part — a script that strips the offending headers is the
obvious remedy and it does not work. In `documents/consumer.py` the mime
type is detected and the parser class chosen *before* the hook runs:

```python
mime_type = magic.from_file(self.working_copy, mime=True)   # ~line 418
parser_class = ...                                          # locked in here
...
self.run_pre_consume_script()                               # ~line 476, too late
```

Any fix has to happen before the file reaches `consume/`.

Worse, the failure is lossy. With no renderer available Paperless does not
skip conversion — it **converts the email to plain text at ingest and stores
that as the original**, so the stored file becomes `<subject>.txt` and the
`.eml` is gone. `document_archiver` cannot repair those afterwards: it
dispatches on the recorded mime type, correctly picks the text parser, and
silently produces nothing. Documents imported that way have to be re-saved
from the mail client and re-consumed.

#### Why not Tika + Gotenberg

Paperless supports both natively (`PAPERLESS_TIKA_ENABLED` adds
`paperless_tika` to `INSTALLED_APPS`) and together they render `.eml` to
PDF properly. This was deployed, verified working — a test email produced a
valid 63 KB, 3-page PDF and the logs showed `paperless.parsing.mail:
Sending content to Tika server` — and then **removed again**.

It worked, but it cost **~2.1 GB of images** (Gotenberg 1.72 GB, bundling
Chromium *and* LibreOffice; Tika 422 MB) on an install that is otherwise two
lean containers. And it did not actually solve the problem, because the
`X-Mozilla-*` headers meant Thunderbird's `.eml` files never reached the
mail parser to be converted in the first place. Solving it at the source —
having Thunderbird emit PDFs — removed the need for both services entirely.

If it is ever revisited: neither service has **any** authentication, so
neither may be published; reach them by service name over the project
network. Gotenberg renders arbitrary inbound email HTML in a headless
Chromium, so `--chromium-disable-javascript=true` and
`--chromium-allow-list=file:///tmp/.*` are a security control rather than
tuning.

#### Why not Paperless's own IMAP rules

Scoped and parked rather than rejected outright, but it looks weaker the
more clearly the consume folder is understood as *the* interface.

Its genuine attractions: messages fetched over IMAP never carry Mozilla
headers, and consumption scope 2 ("full Mail with embedded attachments as
`.eml`") would produce a single document rather than a message and its
attachments needing linking afterwards.

Against that, it would not replace the consume folder — it would run
*alongside* it as a second, Paperless-specific ingestion path, reachable
only from this deployment and useful only for email. That is the opposite
of the property that makes the current design worth having. It also needs a
relay inside the container's network namespace, because Bridge's certificate
carries `SAN=['127.0.0.1']` only and Paperless verifies hostnames with no
option to disable it, and it needs a Bridge password — a full-mailbox
credential — living in the same container that write-mounts the document
store.

See the `host.containers.internal` section for why Bridge is reachable from
a container at all, which is the one part of this that was genuinely
surprising.

### Triage: the "Consume to Inbox" workflow

Everything arriving needs tagging, so a Paperless **workflow** marks it on
the way in:

| Field | Value |
|-------|-------|
| Name | `Consume to Inbox` |
| Sort order | `0` |
| Trigger | `Consumption Started` |
| Action | `Assignment` → assign tag `Inbox` |

**Sort order is not optional and the form does not prefill it** — it is an
`IntegerField`, `null=False`, default `0`, so leaving it empty fails
validation with "This field may not be null". It only matters when several
workflows could act on the same document, running low to high.

Set the `Inbox` tag's matching algorithm to **none**, not `auto`. The other
tags here are on `auto`, meaning the classifier learns when to apply them —
correct for `Health & Wellbeing`, wrong for a tag a workflow applies
unconditionally, where it would only feed noise into a classifier that has
just started producing useful suggestions.

Paperless also has a native alternative, `Tag.is_inbox_tag`, which applies a
tag to every new document regardless of source and drives the dashboard's
inbox count. The workflow was chosen instead because it can be scoped by
source (`ConsumeFolder`, `ApiUpload`, `MailFetch`, `WebUI`) if that ever
becomes useful.

### Monitoring

Uptime Kuma monitor at `https://status.mathewcsims.uk` — monitors are UI
state in `uptime-kuma/data/`, not anything this repo deploys, though they
can be written straight into `kuma.db` (see the app recipe's step 9):

| Field | Value |
|-------|-------|
| Monitor type | `HTTP(s) - Keyword` |
| Friendly name | `Paperless` |
| URL | `https://paperless.mathewcsims.uk/api/remote_version/` |
| Keyword | `version` |
| Tags | `Homelab`, `Heart of Gold` |
| Status page | `Services`, position 14 |

Tags follow the convention every other monitor uses: `Homelab` plus a host
tag, `Heart of Gold` being the Mac. `Services` is ordered alphabetically, so
Paperless sits between `Owl document-viewer` and `Rep's Notes` — weight 15
was free (a gap left by a decommissioned app), so `Rep's Notes` moved 14→15
and Paperless took 14 rather than renumbering the whole group.

`/api/remote_version/` is the right target: it answers **unauthenticated**
with `{"version":"v3.0.5","update_available":false}`, unlike `/api/status/`
and `/api/ui_settings/` which both 401. A plain `http` check of `/` would
also "work", but only proves Caddy is up — `/` merely 302s to the login
page, which it would do with a broken database behind it. The keyword check
proves Django is actually serving.

Verified that this passes the LAN gate before setting it up: Kuma runs on
the Pi (`10.0.1.19`), which is in `private_ranges`, so the `@lan` matcher
admits it. Confirmed by curling the endpoint from the Pi itself and getting
a 200 with the expected body.

### Paperless depends on the NAS being up

A consequence of putting the media root on a share, and worth knowing before
it surprises you at 3am. The CIFS volume is mounted when the container
starts, so **if Eddie is unreachable, Paperless does not start** — the
container exits with `mount error(...)` rather than starting in a degraded
state. Nothing else in this repo behaves that way; every other Mac app is
self-contained on local disk.

In practice this is self-correcting: `restart: unless-stopped` means podman
keeps retrying, and `autostart/podman-autostart.sh` needs no per-app
registration (it starts everything with a restart policy), so after a power
cut Paperless comes up on its own once the NAS is back. But the ordering is
real — if Paperless is down and nothing obvious is wrong with it, check
whether Eddie is up before debugging the container.

The mount is `soft` (visible in `mount | grep cifs` inside the container),
which is the right choice here rather than the default reflex of `hard`: a
NAS that goes away mid-operation returns I/O errors instead of blocking
processes in uninterruptible sleep. Given this repo has already lost 40
hours of backups to exactly that failure mode, do not "fix" this to `hard`.

### Metadata suggestion: the classifier is on, the LLM layer is not

Two capabilities, routinely conflated because both get called "the AI bit".

**The classifier** is what suggests tags, correspondent, document type and
storage path. scikit-learn, entirely local, no external calls, and **on by
default** — `PAPERLESS_TRAIN_TASK_CRON` retrains hourly at :05. There is
nothing to configure. It learns from your own filing decisions, so it does
nothing at all until there is a corpus; file a few dozen documents with tags
and correspondents and suggestions appear on their own.

Worth knowing alongside it: per-tag matching supports `MATCH_LITERAL`,
`MATCH_REGEX` and `MATCH_FUZZY`, none of which need training. For a rule
like "anything mentioning the NHS number gets tagged Medical", a regex match
beats the classifier and works from the first document. `MATCH_AUTO` is the
mode that defers to the classifier.

**The LLM layer is deliberately off.** 3.x ships a complete `paperless_ai`
package — embeddings, vector store, document chat — so the RAG layer this
repo would once have needed a third-party tool for is now native. Unlike the
classifier it works zero-shot, so it would be useful immediately.

It stays off because this instance holds personal medical and legal
documents and the classifier already covers what the store is for. The
decision to revisit is "what is the classifier actually missing", answerable
only once there are documents.

If it is ever turned on, the live options (read from the running container,
not the docs):

- `PAPERLESS_AI_LLM_BACKEND` — `ollama` or `openai-like`
- `PAPERLESS_AI_LLM_EMBEDDING_BACKEND` — `huggingface`, `ollama` or
  `openai-like`. **`huggingface` runs embeddings locally inside the
  container**, no external calls, whichever LLM backend is chosen — so
  "local embeddings, cloud LLM only for the retrieved chunks" is a
  supported shape rather than something needing to be built.
- `PAPERLESS_LLM_INDEX_TASK_CRON` — vector index rebuild, default daily
  02:10.

There is already an Ollama on the Mac (`qwen3.5:4b`), and it **is** reachable
from inside the container at `http://host.containers.internal:11434` — no
change to Ollama, nothing exposed beyond the container. `../litellm/` is not
an option here at any point: employer-funded infrastructure, personal
medical documents.

> **Correction, 2026-08-04.** This section originally said the opposite —
> that Ollama binds `127.0.0.1` and would need `OLLAMA_HOST=0.0.0.0`,
> exposing it to the LAN. That was wrong, and it was wrong in a way worth
> keeping on the record, because the intuition behind it is a trap. See
> below.

### `host.containers.internal` reaches the Mac's loopback

Generally useful, and repeatedly counter-intuitive on this host:

**gvproxy forwards `host.containers.internal` (`192.168.127.254`) to the
*Mac's* loopback, not the VM's.** So a service bound to `127.0.0.1` on the
Mac — Ollama, Proton Mail Bridge, anything — is reachable from inside a
container, with no rebinding and nothing exposed to the LAN.

The trap is that the reverse intuition also holds, and the two together
catch people out:

- **Mac loopback → reachable** from containers via `host.containers.internal`.
- **The Mac's LAN IP is NOT a route to those services.** `10.0.1.14:11434`
  is refused, because Ollama isn't listening on that interface.
- **The gateway does not blanket-accept.** Ports with nothing behind them
  give `ConnectionRefused` (checked 9999 and 54321), so a successful connect
  is real evidence, not an artefact.

Two things to watch when testing this:

- **`/dev/tcp/host/port` is a bash feature and the containers run dash**, so
  it reports every port as closed. It will tell you the NAS is unreachable
  while a working CIFS mount to that exact host sits in front of you. Use
  Python's `socket` instead.
- **A silent connect is not a dead port.** Bridge's IMAP accepts and then
  says nothing, because it is implicit TLS waiting for a ClientHello — not
  STARTTLS, which would greet first. Complete the handshake before
  concluding anything.

### Task-failure alerts (`notify-failed-tasks.py`)

Added 2026-08-05, directly because of the classifier OOM below: nine hours
of hourly failures produced no alert of any kind, and were noticed only by
chance from a badge in the web UI.

**Paperless cannot do this itself.** Its workflow system has a Webhook
*action*, but the only triggers are Consumption Started / Document Added /
Document Updated / Scheduled — none fires on task failure. So this polls,
the same shape as `kopia-mac/verify-backups.sh`.

Runs hourly at :20 via `uk.mathewcsims.paperless-task-alert`, deliberately
after the :05 classifier training so a failure is caught in the same hour.
Install:

```
cp paperless/uk.mathewcsims.paperless-task-alert.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/uk.mathewcsims.paperless-task-alert.plist
```

It covers **every** task type, not just `train_classifier` — a failed
`consume_file` means a document was dropped in the consume folder and never
became a document, which is indistinguishable from "not scanned yet" until
you go looking. Failures are grouped by type so nine identical OOM kills
read as one problem rather than nine notifications.

Three design decisions worth not undoing:

- **It reads `db.sqlite3` directly, read-only**, rather than going through
  `podman exec`. That means it still works when the container is unhealthy
  or stopped — which is exactly when failures matter. An alerting path that
  depends on the thing it monitors is not much of an alerting path.
  Precedent: `scripts/dump-databases.sh` already opens these databases the
  same way, and WAL mode permits concurrent readers.
- **State is a high-water-mark file, not the `acknowledged` column.** That
  column is the UI's Dismiss button. Reading it would mean staying silent
  about failures not yet dismissed, which is backwards; setting it would
  dismiss tasks in the UI on your behalf, destroying the very signal that
  surfaced the OOM problem. The two stay independent.
- **The first run is deliberately silent**, recording the current maximum
  task id without alerting. Otherwise deployment's first act would be a
  false alarm about historical, already-resolved failures — and an alerting
  system that cries wolf immediately gets ignored.

The notification body is capped at 3500 characters for the same reason
recorded in `trivy-scan/scan.py`: Discord embed descriptions cap at 4096,
and exceeding it 400s the entire Apprise fan-out, taking the ntfy copy down
with it rather than just the Discord one.

Runs under macOS's `/usr/bin/python3` (3.9), matching the trivy-scan agent,
so the file carries `from __future__ import annotations` — 3.9 evaluates
annotations eagerly and `int | None` in a signature raises `TypeError` at
import. `py_compile` does *not* catch this, because compiling never
evaluates annotations; only actually running it does.

### Keep novels (and anything novel-sized) out

Learned the hard way on 2026-08-05, and the diagnosis that looks obvious is
wrong.

Every hourly `Train Classifier` task began failing with `Worker exited
prematurely: signal 9 (SIGKILL)` — a cgroup OOM kill. That reads as an
under-sized `mem_limit`, but raising it from 2 GiB to 4 GiB did **not** fix
it; training still died, peaking at 3.89 GiB.

The cause was the corpus. A batch of novels had been uploaded — 19 documents
totalling 8.17M characters, **98.6% of all text in the instance**. Paperless
vectorises with `CountVectorizer(ngram_range=(1,2), min_df=0.01)`, hardcoded
in `documents/classifier.py` with no setting exposing it, then feeds that to
`MLPClassifier`, whose first layer scales with the feature count. Novels
share almost no vocabulary with each other or with a clinic letter, so
nearly every bigram survived `min_df`. Measured on the real data:

| Corpus | Features | Peak memory | Outcome |
|--------|---------:|------------:|---------|
| 35 docs, 8.28M chars (with novels) | 508,023 | 3.89 GiB | **OOM killed** |
| 17 docs, 432k chars | 33,846 | 2.27 GiB | ✓ 4.2s |
| 14 docs, 88k chars (cleaned) | 9,372 | 1.86 GiB | ✓ 3.2s |

A 54× reduction in features, achieved by deleting documents rather than by
tuning anything. **If training ever OOMs again, look at total text volume
and outsized single documents before touching `mem_limit`.**

It was not only a memory problem. Those 19 documents were 98.6% of what the
classifier was learning from, so it was mostly learning to recognise
fiction — the suggestions it produced for actual correspondence were being
drowned out. A single 319k-character conference programme had the same
effect in miniature and was removed for the same reason.

Paperless is built around correspondence and records: things with
correspondents, dates and reference numbers. A novel has none of those. Keep
libraries in something built for them.

### The classifier model is excluded from backups

`data/classification_model.pickle` is **86 MiB and regenerated hourly**.
Left alone it would push ~86 MB of genuinely new data into every nightly
Kopia snapshot, because retrained float weights do not dedupe against the
previous run's.

It is regenerable machine state, exactly like the `.cache/`, `.ollama/` and
`.minutes/models/` exclusions already in the home-directory policy — restore
from backup and it rebuilds within the hour from documents that *are* backed
up. So it is ignored, on **both** sources that cover it:

```
kopia policy set ~/self-hosted/paperless/data --add-ignore '/classification_model.pickle'
kopia policy set ~                            --add-ignore '/self-hosted/paperless/data/classification_model.pickle'
```

Both are needed: `paperless/data` is its own source *and* sits inside the
home-directory source, so excluding it in one place alone leaves the other
still uploading it. Verified by snapshotting and listing the result — the
snapshot contains `db.sqlite3`, `index` and `log`, and not the model.

### Orphaned files after deleting documents

`document_sanity_checker` reports orphaned blobs but **cannot remove them**
— it has no cleanup flag. Deleting through the UI and emptying the trash
there does clean up properly; what leaves orphans is `hard_delete()` from
the Django shell, which drops the database rows and bypasses the
file-cleanup signal.

Seven such files (1.3 MB) were left behind by earlier shell deletions and
removed by hand. If the checker ever reports orphans, compare the files on
the share against `Document.source_path` / `archive_path` /
`thumbnail_path` rather than parsing the checker's wrapped table output.

### Backups — deliberately half a source

`kopia-mac/backup.sh` snapshots `paperless/data` (SQLite database, Tantivy
index, classifier) and **nothing on the NAS**. Adding a NAS source here
would recreate the 40-hour uninterruptible-I/O wedge documented at the top
of that script — a static PDF store is a far gentler workload than the Time
Machine sparsebundle was, but a process stuck in state U does not die on
SIGKILL, and the blast radius is every source that night plus every
subsequent night.

The blobs are covered separately, and off this repo's infrastructure: the
NAS has its own backup arrangements for the data living on it, which is why
nothing here reaches onto the share.

**No scheduled `document_exporter`, and that is a decision rather than an
omission.** The command exports every document plus a `manifest.json` of all
database metadata (tags, correspondents, types, dates, notes, saved views),
which `document_importer` can restore into *any* Paperless — so unlike a
Kopia snapshot of `db.sqlite3` plus blobs, it does not depend on landing on
a compatible schema version. It is also the only restore path that cannot
hand you a database and a blob store captured at different moments, since
the two halves here are backed up by different systems on different
schedules.

Both of those are real, and neither is worth the duplicate copy of every
document here, because they insure against the wrong things:

- **The threat model is hardware failure**, which the split backup already
  covers completely.
- **The documents themselves survive independently** of Paperless and of
  this repo — they are on the NAS, backed up on their own terms, and remain
  readable PDFs whatever happens to the application.

That leaves only exotic cases — a major-version upgrade going wrong, SQLite
corruption, or migrating off Paperless entirely — where the DB dump plus
the blobs would not be enough. `PAPERLESS_EXPORT_DIR` is configured and
points at the share, so the command is there to run by hand if one of those
ever arrives:

```
podman exec paperless python3 manage.py document_exporter /usr/src/paperless/nas/export -c -d
```

Revisit the scheduling question only if the value of the metadata (the
tagging and filing work, which is the part *not* recoverable from the raw
PDFs) ever outgrows the cost of a second copy.

---

## HedgeDoc / Docs (https://docs.mathewcsims.uk) — LAN-only, runs on the Mac

Personal Markdown authoring space. Real-time notes, a document list, per-note
permissions, and proper accounts. Friends and family on the tailnet can be given
accounts.

### Why it has BOTH a LAN gate and its own login

The Caddy gate admits any device on the LAN or the tailnet, which is the
availability wanted — but it is not an *identity*. It cannot distinguish one
tailnet device from another, and these are personal drafts. HedgeDoc's own
accounts supply the identity, and notes default to owner-only.

### Why HedgeDoc and not Etherpad

An Etherpad instance was built for this and torn down the same day. Its
`requireAuthentication` is HTTP Basic only — a native browser prompt, credentials
cached by the browser, and no usable logout — it has **no per-note permissions
at all**, and its own OIDC provider cannot serve pad login (core accepts only
Basic, and the provider's endpoints sit behind that same gate). None of that was
fixable by configuration. Two bugs found along the way were filed upstream
([ether/etherpad#8109](https://github.com/ether/etherpad/issues/8109),
[ether/ep_comments_page#454](https://github.com/ether/ep_comments_page/issues/454)).

### The trap: HedgeDoc builds ABSOLUTE URLs

Every asset URL comes from `CMD_DOMAIN` + `CMD_PROTOCOL_USESSL` +
`CMD_URL_ADDPORT`, **not** from the incoming request. Set them to the
container's values instead of the public ones and you get a completely unstyled
page with every asset 404ing. They must describe how a *browser* reaches this:
`docs.mathewcsims.uk`, SSL true, no port. This fails loudly and immediately, so
an unstyled page after a config change means look here first.

### Accounts

Self-registration is off, so accounts only exist because you made them:

```
./scripts/docs-add-user.sh someone@example.com
```

That prints a generated password once and stores nothing — put it in Proton
Pass or hand it over. Remove one with `./scripts/docs-add-user.sh --delete
someone@example.com` (which does **not** delete their notes).

**The permission model, and its limit.** Each note is owner-controlled with six
levels: Freely, Editable, Limited, Locked, Protected, and Private. New notes are
**Private** (`CMD_DEFAULT_PERMISSION=private`) — verified that a private note
returns **403** to a different signed-in account and does not appear in that
account's History. But permissions are owner / all-signed-in / guests: there is
**no per-person sharing**. Sharing a note shares it with everyone who has an
account.

### /status and /metrics are blocked at the proxy

HedgeDoc serves both without authentication, exposing note counts,
registered-user counts and who is online. Caddy `abort`s them (verified: 200 for
`/`, connection closed for `/status` and `/metrics`). Two consequences:

- The container healthcheck reaches `/status` on `127.0.0.1` **inside** the
  container, so it is unaffected.
- Uptime Kuma therefore monitors `/` instead — see below.

### Monitoring

| Field | Value |
|---|---|
| Monitor type | `HTTP(s) - Keyword` |
| Friendly name | `Docs` |
| URL | `https://docs.mathewcsims.uk/` |
| Keyword | `HedgeDoc` |

`/` returns 200 without authentication and contains that string (verified), so a
keyword monitor works even though the app is behind a login. Kuma runs on the
Pi, which is in `private_ranges`, so the LAN gate is not an obstacle.

The `dump-databases.sh` post-dump health-check loop needs no special handling —
it already treats 4xx as healthy and only alerts on 5xx or no response.

### The healthcheck uses node, not wget

The HedgeDoc image ships **no wget, curl, nc or python3** — only node. A
wget-based healthcheck would report the container permanently unhealthy while
the service was fine (a mistake already made once on the Etherpad instance this
replaces). It also uses `127.0.0.1`, not `localhost`, because localhost can
resolve to `::1` first while the app listens on IPv4.

### To bring it up on a fresh machine

1. Create the Pass item once, under your own pass-cli session (agent tokens are
   read-only for item creation):
   ```
   ./scripts/pass-create-docs-secrets.sh
   ```
2. Deploy:
   ```
   ./scripts/pass-deploy.sh docs
   ```
   Never a bare `podman compose up -d` — `POSTGRES_PASSWORD` would be empty and
   Postgres would initialise with trust authentication.
3. Create your account with `./scripts/docs-add-user.sh`.
4. Add the DNS records and the Caddy block (see the general recipe below), copy
   the Caddyfile to the Pi and `docker compose restart caddy`.

### Backups

`docs/pgdata` is dumped nightly by `scripts/dump-databases.sh` (`dump_postgres
docs-postgres hedgedoc hedgedoc docs`). **`docs/uploads/` is a separate Kopia
source and matters just as much** — it holds every image pasted into a note, it
is gitignored, and it exists nowhere else. A restore without it gives you notes
full of broken images.

---

## organice (https://org.mathewcsims.uk) — DECOMMISSIONED

> **DECOMMISSIONED 2026-08-08, one day after deployment.** Tried in earnest and
> abandoned: neither organice on the desktop nor Orgzly Revived on Android was
> good enough in daily use. Container, image, app directory, Caddy site block,
> both DNS records and the Uptime Kuma monitor are all gone; the compose project
> lives on only in git history.
>
> **The org files are preserved** at
> `db-dumps/decommissioned/organice-orgtasks-data-*.tar.gz`, following the same
> convention as Marque, Nimbus, TimeTagger, Speedtest Tracker and HealthLog — the
> archive sits in a Kopia source, so it rides along with every future backup.
>
> **copyparty was fully reverted**: the `[/orgtasks]` volume, the scoped
> `orgtasks` account, the `daw` volflag and the `acao`/`acam` CORS allowance are
> all removed, and **`vague-403` is restored** now that nothing here speaks
> WebDAV. See the note beside it in `copyparty/cfg/copyparty.conf`.

### What was learned, and is worth not re-deriving

The exercise was a search for a recurring-task system. It failed, but narrowed
things usefully:

- **The binding requirement is from-completion recurrence surviving sync** —
  "x hours/days/weeks after I last did it", on more than one device, with the
  next occurrence appearing *instantly* on completion. That last part forces
  recurrence to be computed client-side, which forces the rule to sync.
- **RFC 5545 cannot express it.** There is no `VTODO` representation for
  "recompute from completion", so anything syncing over CalDAV loses it. Apps
  that support the behaviour carry it in vendor extensions.
- **Tasks.org** does everything else — both recurrence patterns, `ring_nonstop`
  nagging, exact alarms, a real desktop build — but never syncs `repeat_from`.
  Upstream issue [#2009](https://github.com/tasks/tasks/issues/2009) has been
  open since Sept 2022 with **no maintainer response**, the analogous PR #3782
  has been open a year, and only three human PRs merged in the last hundred
  (largest +36 lines). A patch would be a permanent fork.
- **Super Productivity** satisfies every functional requirement — from-completion
  in `sync.model.ts`, nagging on all platforms, WebDAV blob sync to copyparty —
  but its Android client is a **WebView on a URL hardcoded in `BuildConfig`**, so
  its launch-screen quote cannot be removed without rebuilding the APK.
- **Mindwtr** syncs its own `strategy: strict|fluid` but does not nag
  (`loop_sound` hardcoded false, no boot receiver).
- **Server-owned recurrence is not viable**: Android's `WorkManager` enforces a
  15-minute floor on periodic sync, so a completed task cannot show its next
  occurrence promptly.
- **No mechanism gives an insistent alarm on both Android and macOS.** Android
  permits alarm-stream audio; macOS notifications do not repeat and a service
  worker cannot play audio. ntfy does have per-subscription `insistent` and
  `dedicatedChannels`, which is genuinely alarm-grade **on Android only**.
- **A physical system fails on travel** — roughly two weeks in four away from
  home, so anything anchored to the house is unusable half the time.

Do not restart this search from scratch. Screen candidates on: does the sync
format carry the app's own semantics; is recurrence computed client-side; does
it nag; is there a usable desktop client.

## Adding another app (the general recipe)

Three patterns, depending on where the app runs:

### Mac-resident app (copyparty, Memos — the default)

Every Mac app so far follows the same shape — copy it for the next one:

1. `mkdir self-hosted/<app>` with its own `compose.yaml` + data folder(s).
2. Publish its port bound to the Mac's actual LAN IP (`10.0.1.14:<port>:<port>`)
   — podman-machine cannot bind `0.0.0.0` to the real interface (see
   Troubleshooting). Never let the router forward that port; the Pi is the only
   public entry point.
3. Set an explicit top-level `name:` in `compose.yaml` if there's any chance of
   a project-name collision with another stack on this Mac (folder-basename
   collisions are the default project name — this bit us once with an unrelated
   pre-existing `memos` stack).
4. If the app builds its own callback/redirect URLs (OAuth, webhooks, etc.),
   give it its public HTTPS URL via whatever env var it supports (Memos:
   `MEMOS_INSTANCE_URL`) — otherwise those URLs get built from the internal
   Mac address and break.
5. Add a hostname block to `pi-reverse-proxy/Caddyfile`:
   - **Hostname (the block's key)** — hardcode it. An unset/empty env var used
     as a site block's key produces an invalid keyless `{ }` block that crashes
     Caddy on startup — that's what happened with the first `mc37` attempt.
   - **Backend address** — use `{$MAC_IP}` (e.g. `reverse_proxy http://{$MAC_IP}:<port>`).
     It's just a value inside the block, not a key, so it doesn't have that
     failure mode, and it's already wired into `compose.yaml`'s `environment:`
     block on the Pi — one source of truth if the Mac's LAN IP ever changes.
     Only hardcode a backend IP too when it's genuinely a one-off (e.g. the
     DrayTek's own IP in the `mc37` block, which nothing else references).
6. DNS: public `A` record (registrar) for cert issuance, plus a NextDNS
   rewrite so LAN devices resolve straight to the Pi.
7. Copy the Caddyfile to the Pi, `docker compose restart caddy`.
8. **Back it up.** Add the app's data directory to `kopia-mac/backup.sh`'s
   `SOURCES`, and if it uses a database, add it to
   `scripts/dump-databases.sh` too — a live SQLite/Postgres/MariaDB file
   copied while the service runs can capture torn pages. Take one snapshot
   by hand (`kopia snapshot create <path>`) rather than waiting for 02:00:
   it protects the data immediately and registers the source with
   `verify-backups.sh`, which discovers sources from the snapshot list and
   therefore cannot see one that has never been snapshotted.
9. **Add an Uptime Kuma monitor** at `https://status.mathewcsims.uk`. Every
   public hostname in this repo has one, and decommissioning an app
   explicitly removes it — but this step was practice rather than checklist
   until Paperless got deployed without one, so it is written down now.
   Prefer a `keyword` monitor against an unauthenticated health endpoint
   over a plain `http` check of `/`. Kuma runs on the Pi, whose LAN IP is in
   `private_ranges`, so monitors work against LAN-gated hostnames without any
   special handling.

   Monitors are UI state in `uptime-kuma/data/` rather than anything this
   repo deploys, but they **can** be written directly into `kuma.db` when
   the UI is inconvenient — an earlier version of this line wrongly said
   they could not be. Kuma loads monitors into memory at startup, so a row
   inserted this way does nothing until the container restarts. Back the
   database up first, copy the column values from an existing monitor of the
   same type rather than guessing defaults, and remember there are three
   tables involved, not one:

   | Table | Holds |
   |-------|-------|
   | `monitor` | the check itself |
   | `monitor_tag` | tags — convention here is `Homelab` plus a host tag |
   | `monitor_group` | status-page placement, `weight` ordering within a group |

   The `Services` group on the status page is ordered alphabetically, and
   its weights are non-contiguous because decommissioned apps left gaps —
   check for a free weight in the right position before renumbering
   anything.

**If the app needs a database** (copyparty/Memos didn't, but some apps will):
add it as a second service in the same `compose.yaml`. Give it **no `ports:`**
at all — it only needs to be reached by the app container over the private
compose network (by service name), never by the Pi or the host. Only the app
service gets the LAN-IP-bound port.

### Pi-resident app (for resilience, when the app should stay up even
if the Mac is down)

1. `mkdir self-hosted/<app>` on the Mac (still the source of truth), with its
   own `compose.yaml` — but it **deploys to the Pi**: `scp -r` the folder over
   and run it there with `docker compose`, not `podman compose`.
2. **No `ports:` published at all.** Have the app's service join `pi-shared`
   (defined in `pi-reverse-proxy/compose.yaml`, referenced as `external: true`
   in the new app's `compose.yaml` — see `speedtest-tracker/compose.yaml`),
   and proxy to
   it from `pi-reverse-proxy/Caddyfile` by **container name**
   (`reverse_proxy <container-name>:<port>`), not an IP. `127.0.0.1` would NOT
   work here — Caddy runs in its own container, so its own loopback isn't the
   Pi's loopback.
3. Bring `pi-reverse-proxy` up first if `pi-shared` doesn't exist yet (it
   already does — this only matters after a full teardown of both stacks).
4. DNS + Caddy hostname block: same as the Mac-app recipe (hardcode the
   hostname; registrar `A` record + NextDNS rewrite).
5. Auto-start: nothing to add — Docker's `restart: unless-stopped` + Docker
   starting at boot (Pi default) covers it, same as Caddy. The Mac's
   `autostart/` launchd agent is irrelevant to anything Pi-resident.

**If the app has no authentication of its own, or is pure machine-to-machine
plumbing** (Apprise, Speedtest Tracker, the Vikunja webhook relay): gate the
Caddy hostname block to LAN clients only, rather than exposing it to the
internet with just a hope that whatever's behind it is safe. The pattern is
always the same — see `apprise.mathewcsims.uk` in `pi-reverse-proxy/Caddyfile`
for a concrete example:
```
example.mathewcsims.uk {
	import security_headers
	import general_ratelimit example

	@lan remote_ip private_ranges
	handle @lan {
		reverse_proxy example-container:port
	}
	# non-LAN (internet) clients: closed connection, nothing revealed
	handle {
		abort
	}
}
```
A real public `A` record is still needed for cert issuance even though only
LAN clients can ever use the site — the NextDNS rewrite is what makes
LAN devices actually resolve to the Pi's LAN IP instead of round-tripping out
to the WAN IP and back in.

### App on a third host (Immich on slartibartfast — when it belongs on neither existing machine)

Same as the Pi-resident recipe **except the networking**, which follows the
*Mac* pattern instead:

1. `mkdir self-hosted/<app>` on the Mac (still the source of truth), deploy
   with `scp -r` + `./scripts/pass-deploy-remote.sh <app> <ssh-host>
   '<remote-path>'` — that script works against any SSH host, not just the Pi.
2. **Publish a port**, bound to that host's LAN IP (not `0.0.0.0`), and proxy
   to it by IP from the Caddyfile. `pi-shared` and container-name proxying are
   **not available** — that docker network only reaches containers on the Pi
   itself. This is the one real difference from the Pi recipe and it's easy to
   get wrong.
3. Add the host's IP as a **new env var** in `pi-reverse-proxy/compose.yaml`'s
   `environment:` block plus the Pi's `.env` and `.env.example`, following
   `MAC_IP`/`SLARTI_IP`. Also add it to the `caddyfile` CI job's `docker run`
   env flags in `.github/workflows/ci.yml`, or validation fails on the
   unset placeholder.
4. Give the host a **DrayTek DHCP reservation** so the IP never moves.
5. Scheduled jobs on a Linux host: a systemd timer, following
   `pi-unattended-upgrades/reboot-check.timer` (the existing precedent) or
   Immich's Kopia backup for a `--user` variant. The Mac's `autostart/`
   launchd agents are Mac-only.
6. **If the host is on both the LAN and the tailnet**, check
   `ip route get <another-LAN-host>` returns `dev <lan-if>` and not
   `dev tailscale0`. If it's the latter, run
   `sudo tailscale set --accept-routes=false` — see the Immich section for
   the full diagnosis. This silently breaks all inbound LAN traffic while
   leaving outbound looking fine, so it is worth checking up front rather
   than debugging a 502 later.

**If the app is our own code, not a pulled image** (the Vikunja webhook
relay): use `build: {context: ., dockerfile: Dockerfile}` in place of
`image:`, and pin the Dockerfile's own `FROM` by tag and digest, same
discipline as every pulled image elsewhere in this repo. The first
`docker compose up -d` on a fresh machine builds automatically since no
image exists yet — but after editing the app's own code, a plain `up -d`
will **not** pick up the change (compose only builds when the image is
missing), so redeploy with `docker compose up -d --build` explicitly
instead.

---

## Troubleshooting

- **502 Bad Gateway from the domain:** Caddy on the Pi can't reach copyparty.
  Almost always the wrong `MAC_IP` in the Pi's `.env`. The Mac's real IP is
  `ipconfig getifaddr en1` — it MUST match `MAC_IP`, and after changing `.env`
  run `docker compose up -d` (not just `restart`) so Caddy re-reads it.
- **copyparty unreachable on the Mac's LAN IP** (but fine on `localhost`):
  podman-machine only exposes a published port on the *exact* host IP named in
  `compose.yaml` — it cannot bind `0.0.0.0`/the LAN interface. The port line must
  read `10.0.1.14:3923:3923`. If the Mac's IP ever changes, update it there and
  in the Pi's `.env`.
- **Cert never issues:** DNS not propagated, router not pointing at the Pi, or
  the router is holding 443 (SETUP Part 4b).
- **"rejected by cors-check" on login (HTTP 403):** copyparty didn't trust the
  reverse proxy, so it ignored Caddy's `X-Forwarded-Proto: https` and treated
  the HTTPS login as cross-origin. Fixed by the `xff-src: lan` and `rproxy: -1`
  lines in `copyparty/cfg/copyparty.conf` (the request reaches copyparty from
  podman's gateway `192.168.127.1`, which `lan` trusts). **Editing the conf
  needs `podman compose restart copyparty`** — `up -d` alone won't reload it
  because the compose spec is unchanged.

---

## Operations

**Mac (any app)** — run from that app's own folder, e.g. `self-hosted/copyparty/`
or `self-hosted/memos/`:
```sh
podman compose ps          # status
podman compose logs -f     # logs
podman compose restart     # restart
podman compose down        # stop (data is safe)
podman compose pull && podman compose up -d        # update
```
**Pi (Caddy):**
```sh
docker compose ps | logs -f | restart | down
docker compose build --pull && docker compose up -d   # update Caddy (rebuilds
                                                        # from source — it's a
                                                        # custom image now, see
                                                        # Security notes below)
```
After editing just the **Caddyfile** (no Dockerfile change): `docker compose
restart caddy` is enough — it's bind-mounted, not baked into the image. After
editing the **Dockerfile**: `docker compose up -d --build`.

**Pi app (e.g. speedtest-tracker):**
```sh
docker compose ps | logs -f | restart | down
# Update: bump the digest in the app's compose.yaml first (deliberate, see
# Security notes below — not `pull`+`latest`), then:
docker compose pull <service> && docker compose up -d
```

---

## Auto-start on reboot

- **Pi:** Docker's `restart: unless-stopped` + Docker starting at boot (default)
  means Caddy returns on its own. Nothing to do.
- **Mac:** set up in two parts (covers **all** podman containers, every compose
  project — not just copyparty):
  1. **`podman-restart.service`** is enabled inside the podman VM. On each VM
     boot it starts every container with a restart policy (filter
     `should-start-on-boot=true`).
  2. **launchd agent** `~/Library/LaunchAgents/uk.mathewcsims.podman-autostart.plist`
     runs `autostart/podman-autostart.sh` at login, which starts the podman
     machine (and, as an idempotent safety net, starts the containers too).
     Logs to `autostart/autostart.log`.

  **Caveat:** a launchd *agent* runs at **GUI login**, and podman-machine can
  only run inside your user session — so after a reboot the containers come back
  once you **log in**. For fully unattended start, enable Automatic Login
  (System Settings ▸ Users & Groups ▸ Automatic login).

  Manage the agent:
  ```sh
  launchctl bootout   gui/$(id -u)/uk.mathewcsims.podman-autostart   # disable
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/uk.mathewcsims.podman-autostart.plist  # enable
  ```
  Disable the in-VM service with:
  `podman machine ssh systemctl disable podman-restart.service`.

### Podman VM sizing (OOM wedge, diagnosed 2026-07-19)

The podman machine now runs with **8 GiB** memory (`podman machine set
--memory 8192`). It originally had ~4.6 GiB, which was enough when the
stack was small but silently became too little as services were added:
with all ~26 containers up, the guest kernel ran out of memory (serial
console showed `Out of memory: Killed process ... (chromium)` ~4½ min
after boot) and then thrashed zram swap, pegging all 5 vCPUs — the
`krunkit` process sat at >500 % CPU while the API socket, `podman ps`,
and `podman machine ssh` all hung. From the outside this looks like "the
podman machine crashed"; `podman machine stop` can't recover it (the
graceful stop times out and even after a hard stop the state can report
"already running"). It wedged this way twice before diagnosis.

Recovery, if it ever recurs: `pgrep krunkit`, `kill -9` it, then
`podman machine start` — every container comes back automatically via
`podman-restart.service`. Watch for the wedge returning within minutes
(that's the tell that it's memory, not a one-off). Check headroom with
`podman machine ssh free -m`; if "available" is regularly under ~1 GiB,
raise the allocation again before adding the next service.

- Back up **`copyparty/data/`**, **`memos-prospect-ukri-tus/data/`**, and
  **`vikunja/db/` + `vikunja/files/`** on the Mac (Time Machine covers all of
  these if under your home dir). That's all your actual data.
- The Pi's `caddy_data` volume holds the TLS certs/account — nice to keep, but
  Caddy re-issues automatically if lost.
- **`uptime-kuma/data/` on the Pi** holds your monitor config and history —
  the Pi isn't covered by Time Machine, so back this up separately if you
  care about keeping it (Kopia does; see the Kopia section).

---

## Security notes (internet-facing)

- copyparty has **no anonymous access** to `/` or `/inbox`: every visitor to
  those must log in. Keep it that way.
- The Pi's Caddy serves only the five configured hostnames and refuses any
  other hostname or bare-IP hit (`:80`/`:443` catch-all blocks at the bottom
  of the Caddyfile just `abort`) — so scanning the public IP reveals nothing.
- **Restricting LAN-only ports.** See the dedicated section below.
- Keep every image updated (the `pull && up -d` commands above) — but review
  before pulling: copyparty, Nimbus, and Vikunja are all pinned to an exact
  tag/digest deliberately (see each app's compose.yaml), so an upgrade is a
  conscious decision, not something that happens silently on a routine
  restart.
- Use a long unique admin password per app (already generated where relevant).

### Restricting LAN-only ports (copyparty)

> **⚠️ macOS UPDATES SILENTLY DISABLE THIS. READ THIS FIRST.**
>
> A system update replaces `/etc/pf.conf` with Apple's stock file, which
> removes the two lines from `pf-conf-snippet.txt` that reference our anchor.
> The anchor file itself survives in `/etc/pf.anchors/`, untouched and
> irrelevant, because nothing loads it any more.
>
> **Nothing reports an error when this happens.** `pfctl -f /etc/pf.conf`
> genuinely succeeds — it just loads a ruleset that references nothing — so
> the LaunchDaemon reports success at every boot and `reload.log` looks
> healthy while enforcing nothing at all.
>
> This happened, and it was found by accident on **2026-08-08**, weeks after
> the fact, while narrowing the ruleset for the Vikunja teardown:
> `pfctl -s Anchors` listed only `com.apple`, and
> `pfctl -a com.mathewcsims.lan-lockdown -s rules` returned
> `DIOCGETRULES: Invalid argument`. For that whole period copyparty's `:3923`
> was reachable from any device on the LAN — still behind copyparty's own
> login, so a missing defence-in-depth layer rather than an open door, but
> not what this section claimed.
>
> **`reload.sh` now detects and self-heals this** (see below), so the
> exposure window is one boot rather than indefinite. The warning stays here
> because the failure is invisible without it.

Every Mac-hosted app publishes its port bound to `10.0.1.14`, reachable by
any device on the LAN, not just the Pi's Caddy — intended to be reached
only via Caddy's TLS + rate-limiting, with direct LAN access as an
unnecessary (if still login-gated) extra path in. Fixed for copyparty via a
macOS `pf` firewall rule — see `pf-lockdown/`. Vikunja's `:3456` was covered
here too until it was decommissioned on 2026-08-08.

**Why not fix this at the app level instead?** Tried copyparty's own
`--ipa` (IP allow-list) option first — it doesn't work here. Behind
podman's published-port NAT, copyparty only ever sees podman's *internal
gateway IP* as the connection source, never the real LAN IP (confirmed
against [copyparty issue
#1109](https://github.com/9001/copyparty/issues/1109)) — setting `ipa` to
the Pi's IP blocked the Pi too, along with everyone else. A firewall-layer
rule was the only approach that actually works.

**What the rule does:** `pf-lockdown/com.mathewcsims.lan-lockdown` allows
TCP to `10.0.1.14` port `3923` from `10.0.1.19` (the Pi) only, and blocks
everyone else — scoped to exactly that port; nothing else on this Mac is
affected.

**What `reload.sh` does, and why it does more than reload.** It re-adds the
anchor lines to `/etc/pf.conf` if they have gone missing (idempotent —
guarded by a `grep`, so repeated runs cannot duplicate them), reloads, then
**asserts the anchor is in the kernel and holds a non-zero rule count**.
That last part is the important one: `pfctl -a <anchor> -s rules` exits 0
with no output for an anchor that exists but is empty, so exit status is not
a usable check and the rule count is. It alerts via Apprise on failure, and
also on a successful repair — because something overwriting a system file is
worth knowing about even when it fixes itself.

**The alert retries, and that is load-bearing.** This runs from a
LaunchDaemon with `RunAtLoad`, so it starts early — quite possibly before
networking can reach `apprise.mathewcsims.uk` on the Pi. A single
fire-and-forget `curl` would fail exactly when it matters most: the boot
immediately after a macOS update, which is the one boot that has something
to report. So `notify()` retries for ~2.5 minutes and, if it still cannot
get through, records that failure in `reload.log`. A notification that
quietly fails to send is the same category of problem as a check that
quietly passes.

Only the failure and repair paths notify at all, so a clean boot sends
nothing and adds no delay. The retry cannot hold up boot either — the repair
is local and already done by then, and LaunchDaemons run in parallel rather
than in sequence with login.

The rule count deliberately matches rule verbs (`pass`, `block`, `match`…)
rather than counting non-empty lines, because `pfctl` prints `No ALTQ
support in kernel` on every invocation. Counting lines would report 2 for a
completely empty anchor — passing while enforcing nothing, which is the
failure this check exists to catch.

**One-time setup (needs sudo — run these yourself, not via the agent):**

```
sudo mkdir -p /etc/pf.anchors
sudo cp pf-lockdown/com.mathewcsims.lan-lockdown /etc/pf.anchors/
sudo chown root:wheel /etc/pf.anchors/com.mathewcsims.lan-lockdown
cat pf-lockdown/pf-conf-snippet.txt | sudo tee -a /etc/pf.conf
sudo cp pf-lockdown/uk.mathewcsims.pf-lan-lockdown.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/uk.mathewcsims.pf-lan-lockdown.plist
sudo chmod 644 /Library/LaunchDaemons/uk.mathewcsims.pf-lan-lockdown.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/uk.mathewcsims.pf-lan-lockdown.plist
```

This runs the reload script (which repairs `/etc/pf.conf` if needed, enables
`pf` if it isn't already, loads the ruleset, then verifies the anchor
actually holds rules) at every boot — no per-reboot action needed after this.

**Verify it worked:**

```
sudo pfctl -s Anchors                                 # com.mathewcsims.lan-lockdown must be listed
sudo pfctl -a com.mathewcsims.lan-lockdown -s rules   # must print 6 rules, not nothing
```

Six is the expected count: pass/block on `3923`, pass/block on SSH, and
pass/block on SSH over IPv6. It was **8** before 2026-08-08, because
`port { 3923, 3456 }` expands to one rule per port and Vikunja's `3456` was
still in there.

If that second command prints `DIOCGETRULES: Invalid argument`, the anchor
is not loaded — see the warning at the top of this section. Re-running
`sudo /bin/sh pf-lockdown/reload.sh` now repairs it automatically.

**Then test it functionally, from two hosts** — reading the rules only
proves they loaded, not that they work:

```
# MUST still work — this is Caddy's path in, and breaking it is an outage
ssh mathew@babel 'timeout 5 bash -c "</dev/tcp/10.0.1.14/3923"' && echo OK

# MUST be blocked — any LAN host that is not the Pi
ssh mathewcsims@100.68.10.65 'timeout 5 bash -c "</dev/tcp/10.0.1.14/3923"' || echo "blocked, correct"

# Control: same host reaching the Pi proves LAN routing is fine, so a
# blocked 3923 is the pf rule and not a network fault
ssh mathewcsims@100.68.10.65 'timeout 5 bash -c "</dev/tcp/10.0.1.19/443"' && echo "routing OK"
```

**Curling `10.0.1.14:3923` from the Mac itself IS a valid test — it gets
blocked.** An earlier version of this section claimed the opposite ("traffic
from the Mac to its own LAN address does not traverse `en1`'s inbound
filter"). That claim was wrong, was written on 2026-08-08 on reasoning rather
than measurement, and was corrected the same day on measurement:

```
from the Mac:  10.0.1.14:3923 -> 000    (in the pf anchor)
               10.0.1.14:2368 -> 301    (published, NOT in the anchor)
               10.0.1.14:5230 -> 200    (published, NOT in the anchor)
               10.0.1.14:3000 -> 307    (published, NOT in the anchor)
```

Only the port pf covers is blocked, which isolates pf as the cause rather
than any podman-machine loopback quirk. So the Mac is a perfectly good
second source for the negative test, and needs no SSH.

The two-host test above is still the better one, because it also proves the
**pass** path (the Pi must keep working — breaking that is an outage), which
a single-source test cannot. slartibartfast is reached over its **tailnet**
address there because its `sshd` does not listen on the LAN interface.

### Hardening pass (copyparty, Nimbus, Caddy, Memos)

Applied across the board, on top of what each app section above already
documents (Nimbus's OIDC, Memos's registration policy, copyparty's
`--ban-pw`/`--ban-403`, etc.):

- **Reusable security headers, now on every site.** Originally added for one
  app only.
  `pi-reverse-proxy/Caddyfile` defines a `(security_headers)` snippet (HSTS,
  `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`,
  `Referrer-Policy: strict-origin-when-cross-origin`) and every site block
  imports it. copyparty already sends its own `X-Content-Type-Options` —
  harmless duplicate, not worth extra Caddyfile complexity to dedupe.
- **Rate limiting at the Caddy layer**, via a custom-built image
  (`pi-reverse-proxy/Dockerfile`, `mholt/caddy-ratelimit` compiled in with
  `xcaddy` — Caddy has no rate limiting built in, and this module is the
  standard way to add it). `docker compose build` (not a stock `image:`) now
  produces the running `caddy` image; rebuild after ever editing the
  Dockerfile, and after any Caddy version bump.
  - A `(general_ratelimit)` snippet gives every site its own 300
    requests/minute/IP budget (`import general_ratelimit <name>` — the zone
    name is parameterized so each site's budget is independent, not shared).
    Loose enough not to bother a real browsing session; caps a single
    source's blast radius.
  - **Nimbus specifically** also gets a strict zone scoped to
    `/api/v1/auth/*` — 10 requests/minute/IP. This is the compensating
    control for a real gap: Nimbus has **no brute-force or rate-limit
    protection anywhere in its own codebase** (confirmed by reading its
    source), unlike copyparty (`--ban-pw`/`--ban-403`, on by default) and
    Vikunja (`VIKUNJA_RATELIMIT_*`). Verified live: 15 rapid requests to
    `/api/v1/auth/me` returned 401 (real responses) for the first ~8, then
    429 (rate-limited) for the rest.
  - `order rate_limit first` in the global options block makes every site
    check its rate-limit zones before headers/rewrites/proxying — an
    over-limit request never reaches the backend app at all.
- **copyparty**: added `vague-403` to `[global]` — unauthenticated probes now
  get an identical 404 whether a private path exists or not (not compatible
  with WebDAV, which this setup didn't use at the time). **Removed 2026-08-07
  because it broke Orgzly by suppressing the 401 challenge, then RESTORED
  2026-08-08 when organice was decommissioned — see the organice section.**
  Also made the already-active
  defaults `ban-pw: 9,60,1440` and `ban-403: 9,2,1440` explicit in
  `copyparty.conf` rather than leaving them as an unstated default.
  - **Not applied**: `--usernames` (require a username, not just a password,
    at login). Considered and rejected — it's a global flag with no
    per-volume override, so it would also apply to the `/inbox` drop-box
    login, breaking its deliberately-simple "just share one password" design
    for a marginal gain (the only two usernames, `admin` and `inbox`, are
    both guessable, and both accounts already have strong random passwords
    plus the ban-pw/ban-403 lockouts above).
- **Nimbus**: pinned `nimbus/compose.yaml`'s image from `:latest` to the
  exact digest behind it as of 2026-07-02
  (`turboot/nimbus@sha256:c22c98b5f53...`) — same reasoning as Vikunja's
  version pin: an upstream push can't silently change what's running here.
- **Memos**: image pinned the same way (`:stable` → exact digest, v0.29.1,
  CVE history checked — nothing unpatched applies), plus two purpose-matched
  Caddy rate-limit zones on signin/refresh and on registration specifically,
  since blanket-limiting `/api/v1/auth/*` the way Nimbus's zone does isn't
  right when self-registration is meant to stay open. Full detail in the
  [Memos section](#memos-httpsprospect-ukri-tusmathewcsimsuk) above.

---

### Hardening pass 2 (Pi SSH, Mac SSH, fail2ban, unattended-upgrades)

Triggered by both hosts now serving real internet-facing traffic. A live
read-only audit of the Pi, this Caddyfile's own conventions, and the Mac
turned up four concrete gaps, each closed using this repo's existing
tracked-config-as-code + Apprise-notification patterns rather than
one-off manual commands:

- **Pi sshd allowed password auth.** Confirmed via `sshd -T`:
  `passwordauthentication yes`, with `sshd` bound to `0.0.0.0:22`/`[::]:22`
  — yet there's no `~/.ssh/authorized_keys` at all; every real login goes
  through Tailscale SSH instead (implemented inside `tailscaled`, bypasses
  system sshd entirely). New drop-in `pi-sshd/pi-sshd-hardening.conf` →
  `/etc/ssh/sshd_config.d/`, sets `PasswordAuthentication no` (root login
  stays `without-password`, sshd itself stays running as a fallback).
  Verified live: `sshd -T` now reports `passwordauthentication no`,
  `permitrootlogin` unchanged, `ssh.service` stayed active throughout
  (`reload`, not `restart`). **Whether the DrayTek forwards WAN port 22 to
  the Pi is unconfirmed from software** — only 80/443 are documented as
  forwarded; check the router's own port-forwarding table directly if you
  want certainty.
- **Mac SSH Remote Login had no firewall rule at all.** macOS's
  Application Firewall is off, and Remote Login listens on
  `0.0.0.0:22`/`[::]:22` system-wide, reachable from the whole LAN and any
  Tailscale tailnet peer — uncovered by the existing `pf-lockdown` anchor
  (which only restricted copyparty/Vikunja). Restricted, not disabled
  (Remote Login is actively used): extended
  `pf-lockdown/com.mathewcsims.lan-lockdown` with a `<ssh_trusted>` table
  (`10.0.1.19` + `100.64.0.0/10`), mirroring the same
  `private_ranges` + explicit Tailscale-CGNAT pairing already used by
  Caddy's own `@lan` gates. Redeployed the same way as the original
  anchor (copy → `/etc/pf.anchors/`, `pfctl -f /etc/pf.conf`). Verified
  live: `pfctl -a com.mathewcsims.lan-lockdown -s rules` now shows 6 rules
  (the existing 4 for copyparty/Vikunja plus the new pass/block pair for
  port 22); confirmed the Pi can still reach the Mac's SSH port (TCP
  connects through to the host-key exchange stage).
  - **Caught in PR review, fixed before merge: the rules above only ever
    matched IPv4.** A dotted-quad address specification implicitly scopes
    a pf rule to `inet`, never `inet6` — and this Mac's own LAN interface
    already has a real IPv6 link-local address regardless of the ISP
    having no IPv6 WAN support at all (link-local is self-assigned by the
    OS via SLAAC purely for same-segment communication, no ISP/WAN routing
    involved). Without an IPv6-scoped pair, any other device on the LAN
    could reach Remote Login over IPv6, entirely bypassing the restriction
    above. Added a second table (`<ssh_trusted6>`: the Pi's own link-local
    address, confirmed stable/MAC-derived via `ip -6 addr show scope
    link`; and Tailscale's IPv6 ULA range `fd7a:115c:a1e0::/48`, its
    equivalent of the `100.64.0.0/10` CGNAT range already trusted above)
    and a matching pass/block pair scoped to `on en1` (this Mac's LAN
    interface — IPv6 has no single stable "this Mac's address" literal to
    match against the way the IPv4 rules use `10.0.1.14`, since there's no
    ISP-routed IPv6 address to use). Verified live: `pfctl -a
    com.mathewcsims.lan-lockdown -s rules` now shows 8 rules; `pfctl -a
    com.mathewcsims.lan-lockdown -t ssh_trusted6 -T show` confirms both
    trusted addresses loaded correctly.
- **No OS-level patching at all on the Pi.** Confirmed neither
  `unattended-upgrades` nor its config existed — `apt-daily*.timer` were
  enabled but inert without them. New `pi-unattended-upgrades/` installs
  the package with `Automatic-Reboot "false"` explicit and deliberately
  does **not** add Docker's own apt repo (`download.docker.com`) to the
  auto-patched origins — same manual-review philosophy already applied to
  pinned app image digests elsewhere in this doc; Docker Engine is the
  substrate every app here runs on. Instead of auto-rebooting, a new daily
  `reboot-check.timer` checks `/var/run/reboot-required` and pushes a
  notification through the existing Apprise/Discord pipe if one's needed.
  Verified live: `unattended-upgrade --dry-run --debug` shows Docker's own
  packages checked against the Origins-Pattern but never selected for
  upgrade (only the Debian-security origin is eligible); manually
  triggering the notifier script ran clean end-to-end.
- **No independent host firewall/ban layer on the Pi at all.** Only
  Docker's and Tailscale's own iptables chains gated traffic — no
  `fail2ban`, no `ufw`. Added Caddy's own persisted JSON access log first
  (`pi-reverse-proxy/Caddyfile`'s global `log {}` block + a bind-mounted
  `./logs` volume in `compose.yaml` — nothing was persisted outside the
  container before this, only ephemeral `docker logs` output) as the
  prerequisite for a new `pi-fail2ban/` setup: the stock `sshd` jail
  (`backend = systemd`, since this host has no rsyslog/`auth.log`, only
  journald), and a new `caddy-abuse` jail matching unambiguous
  scanner/vuln-probe paths (`/wp-login.php`, `/.env`, `/.git/`, etc.) in
  the access log. Banning uses a custom `docker-user-multiport` action
  hooked into `DOCKER-USER` — the standard `iptables-multiport` action's
  `INPUT`-chain rule has zero effect against a container's published,
  DNAT'd ports, since that traffic only ever transits the `FORWARD` chain.
  Ban/unban events notify via the same Apprise container as everything else
  in this repo, though **since 2026-08-08 on their own config keys** rather
  than the shared one, split by jail: `caddy-abuse` to ntfy `fail2ban` at low
  priority with no Discord, every other jail to Discord + ntfy `alerts` at
  high priority (see the Apprise section). Verified live end-to-end: the filter regex correctly matches
  a synthetic scanner-shaped log line; feeding two real scanner-path hits
  from a test IP through the actual monitored log file triggered a real
  ban (confirmed in both `fail2ban-client status caddy-abuse` and
  `iptables -L f2b-caddy-abuse`), then cleanly unbanned.
  - **Correction (2026-08-06): the global `log {}` block above did not
    actually produce access logs**, and this jail was therefore watching a
    file that only ever received error-level entries. Caddy's global `log`
    option configures the **default logger's sink** — where log lines are
    written — but requests are logged only for site blocks carrying the
    `log` **directive**, and none had it. Every verification quoted above
    still holds, because all three test lines were fed into the file by
    hand; that is exactly why it went unnoticed, and why the jail's lifetime
    counter stood at precisely 3 (one synthetic + two fed) nine days later.
    Fixed by adding an `(access_log)` snippet imported by all 25 site
    blocks. Re-verified afterwards: a probe with a unique path now appears
    in `logs/access.log`, and `fail2ban-regex` matches the emitted format.
  - **Retuned 2026-08-08: ~67 bans/day down to ~10, with sweep detection
    unchanged.** `maxretry = 2` / `findtime = 300` meant any IP making two
    matching requests within five minutes was banned, which is nearly every
    drive-by scanner. Those bans bought nothing — the probes had already
    finished, and nothing behind this proxy serves PHP — while burying every
    alert worth reading.

    The instinct is to match fewer paths. **Measurement says that is the one
    thing not to do.** 34h of real access log (41.5k lines) was replayed
    through fail2ban's own counting semantics (sliding `findtime` window,
    no re-ban while already banned, `ignoreip` honoured) across candidate
    configs. On the old root-level-only path list, `maxretry = 5` gives
    3.5 bans/day but catches only **5 of the 17** genuine multi-probe sweeps
    in that window, against 15/17 before. Matching less trades away exactly
    the detection that matters.

    What worked was **widening what counts while raising how many it takes**:
    the filter now also matches one-directory-deep variants
    (`/blog/wp-login.php`, `/wordpress/wp-includes/wlwmanifest.xml`,
    `/api/.env`) — 66 of the 429 matching requests in the sample, previously
    invisible because the old regex anchored the whole URI between the JSON
    quotes — and the jail moved to `maxretry = 5` / `findtime = 600`. Result:
    **10.6 bans/day, an 84% cut, with sweep coverage held at 15/17,
    identical to the old settings.** Real sweeps trip it faster than before;
    single drive-by probes no longer trip it at all. `bantime` stayed at 24h
    on purpose — lengthening it would cut repeat bans further, but a good
    share of what lands here is shared egress (Cloudflare edge, GCP/DO NAT),
    and a week-long block on a shared address is a wider blast radius than
    the remaining volume justifies.

    On those Cloudflare addresses specifically — a third of the ban list is
    `104.23.x` / `172.6x-172.7x`, which would be alarming if these sites sat
    behind Cloudflare, because Caddy's `remote_ip` would then be the CF edge
    rather than the real client and the jail would be banning the proxy that
    serves real visitors. **Checked, and they do not:** `msims.link` and
    `mathewcsims.uk` both delegate to `ns[1-3].digitalocean.com` and their
    public `A` records point straight at the WAN IP (queried against
    `1.1.1.1`, not the local resolver, which NextDNS rewrites to `10.0.1.19`).
    So those are scanners *egressing* through Cloudflare, and banning them
    breaks nothing — it is just ineffective, since the campaign rotates
    across the edge range faster than any ban list can follow. That
    ineffectiveness is a large part of why per-IP ban volume was never the
    security control it looked like.

    **Two vhosts are carved out, both demanded by the filter's own
    false-positive rule** (only paths *no* app here could serve legitimately):
    `cp.mathewcsims.uk` (copyparty) is excluded from the prefixed form —
    it is public, with no LAN gate, and serves arbitrary user-named files, so
    a shared folder holding a `.env`, a `config.php` or a `.git/` directory
    would otherwise ban the person downloading it; root-level probes against
    it are still caught, exactly as before. `mc37.mathewcsims.uk` is the
    DrayTek's admin UI, whose **entire interface is `/cgi-bin/*.cgi`** —
    logging in fires six of them before the dashboard renders (seen in the
    log: `wlogin.cgi`, `cgidashboard.cgi`, `certificatedata.cgi`,
    `v2x00.cgi`, `sms.cgi`, `variable.cgi`). Nothing bans it today only
    because the LAN and tailnet are in `ignoreip`; an `ignoreregex` now makes
    that independent of `ignoreip`, at zero cost in coverage since that vhost
    `abort`s every non-LAN client anyway.

    Also fixed in passing: path tails are `[^"]*` rather than `.*`, so a
    pattern cannot run past the end of the JSON `uri` field into later
    fields on the same line, and a trailing `(?:\?[^"]*)?` makes query
    strings match on fixed-path branches — `/.env?debug=1` and
    `/xmlrpc.php?rsd` previously slipped through.

    **Verified before deploying**, since a filter change can fail in both
    directions: a 19-case suite of synthetic log lines built from a real
    Caddy line as template (9 must-match, 10 must-not, including every
    carve-out above and the pre-existing documented exclusions) passes
    completely under `fail2ban-regex`; and on the real corpus,
    `fail2ban-regex` matched **400/400** of the lines the replay model
    predicted and **0/4000** of a sample it predicted would not match, so
    the tuning numbers above reflect the engine's real behaviour and not
    just a model of it. Two gotchas worth keeping: Python's `json.dumps`
    inserts spaces after `:` where Caddy emits compact JSON, so synthetic
    test lines silently match nothing unless built with
    `separators=(",", ":")`; and `fail2ban-client reload` is a *soft*
    reload — measured by stubbing the notifier and counting, it does **not**
    re-issue `actionban` for the existing ban list, so reloading with 53
    IPs banned produces no notification storm and does not drop the bans.

**Manual action items — out of scope for this repo, worth doing
separately:**
1. Check the DrayTek Vigor2866's port-forwarding table directly to confirm
   WAN port 22 isn't forwarded to the Pi (only 80/443 are documented).
2. ~~Review the Tailscale ACL policy~~ — **done, 2026-07-23**, via the
   "Tailscale" Pass item's API key (`TAILSCALE_API_KEY`), not the admin
   console: fetched the live policy over the API, found a real bug in the
   "global resources" grant — `"dst": ["tag:resource-global", "*"]` had a
   stray `"*"`, making it functionally identical to the commented-out
   "allow all connections" default just above it. Any tailnet device
   (including `tag:work`/`tag:family`) could reach ANY destination on ANY
   port, which undermined the Caddy `private_ranges 100.64.0.0/10` LAN-gate
   that BookStack/Forgejo/Apprise/Kopia rely on trusting the tailnet CGNAT
   range as "personal only." Fixed to `"dst": ["tag:resource-global"]`,
   validated via Tailscale's `/acl/validate` dry-run endpoint before
   applying, pushed live, then verified every LAN-gated hostname and a
   tailnet ping still worked post-change. The `tag:personal` grant (full
   access for your own devices) was untouched — this only closed the
   accidental over-grant to everything else.

**Tag structure simplified to exactly three tags, in two passes
(2026-07-25), down from seven** — `tag:work` and `tag:family` deleted
first (confirmed via the API: zero devices carried either, ever),
`tag:resource-friend` retired in favor of a cleaner design, and then
**`tag:resource-global` itself removed entirely**: with no non-owner,
non-friend users existing or planned, "accessible by any tailnet member"
had no one left to usefully apply to — everything either belongs to the
owner (`tag:personal`) or is deliberately shared with a specific trusted
person (`tag:friend`), no third category needed. `tag:funnel` kept — the
`memos` tailnet device actively uses it.

Removing `tag:resource-global` meant: deleting its grant
(`{"src": ["*"], "dst": ["tag:resource-global"], ...}`) and its
`tagOwners` entry, deleting the now-meaningless SSH "main user access to
all" rule (its only `dst` was this tag), and stripping the tag itself
from the 5 devices that carried it (golink, and the four tailnet-only
ScaleTail apps — cyberchef/memos/stirlingpdf/transmute), leaving each
with just `tag:personal` (owner-only by default, per the point below)
plus whatever else they already had (`memos` keeps `tag:funnel`).
Re-adding friend-level access to any of them going forward is a
`tag:friend` device-tag change, made as needed, not an ACL edit.
Independently re-verified afterward: zero functional references to the
old tag remain in the live policy (only two explanatory comments noting
its removal), and every affected device's tag list confirmed via a fresh
API fetch, not assumed from the request that made the change.

- **`tag:personal`** — the owner's own devices. Full access (unchanged).
  Nothing grants access *into* tag:personal from anywhere else — the only
  grant naming it is as a *source*, so it's implicitly owner-only by
  Tailscale's default-deny, not by an explicit block rule.
- **`tag:friend`** — a single tag used as *both* source and destination:
  applied to a trusted person's own device (once invited) AND to any
  resource meant to be shared with them specifically, all ports
  (`"ip": ["*"]`), plus `autogroup:internet` for exit-node routing. Not
  port-restricted to 443, deliberately — verified live, not just
  reasoned, that this is genuinely safe rather than sloppy: SSH access is
  gated by the separate `ssh` section (`tag:friend` isn't in it) not by
  network port reachability, Babel has `RunSSH: true` (Tailscale SSH,
  confirmed via `tailscale status --self --json`) which intercepts
  tailnet-sourced port-22 connections entirely, bypassing the real system
  sshd — this repo's own earlier SSH-hardening work already established
  that. And `ss -tlnp` on Babel confirmed nothing besides 22/80/443 is
  even listening on a host port at all; everything else here follows the
  never-publish-a-host-port pattern (Caddy-internal-network only). So a
  port restriction here would have been redundant, not defense-in-depth
  — removed after Mathew questioned why it was there given the `ssh`
  section already does that job. Currently: Babel (the LAN-gated web
  services — BookStack, Forgejo, Apprise, Kopia).
- **`tag:funnel`** — unchanged, controls who can enable Tailscale Funnel.

**A real mistake was made building this and caught on review, worth
recording exactly**: the first version added `tag:resource-friend` to
Babel and golink *alongside* their existing `tag:resource-global` tag,
without removing it. Since `tag:resource-global`'s grant is
`{"src": ["*"], ...}` — *anyone* on the tailnet, all ports — the careful
new narrow grant was completely superseded by the old broad one for both
devices. It wasn't a broken/invalid config, just one that silently didn't
restrict anything: any tailnet member already had full access to Babel
and golink regardless of the new tag, making the "deliberately narrow"
language describing it simply wrong. Mathew caught this by asking "why
does a friend need a specific grant to access things already tagged
resource-global" — the fix was removing `tag:resource-global` from Babel
entirely (it now carries only `tag:personal`/`tag:friend`), which is what
actually makes `tag:friend`'s narrower grant the operative rule for it.
golink correctly stays on `tag:resource-global` only — it's meant to be
open to everyone, which already includes any friend, so it doesn't need
`tag:friend` too. **Lesson for next time a tag/grant is added to an
already-tagged device: check what its *other* tags already grant before
assuming the new one is what's controlling access.**

The whole thing went through three real design iterations before this —
raw IPs in the grant, then a `"hosts"` alias block for readability, then
the single-shared-tag design above — each validated via `/acl/validate`
and independently re-fetched afterward to confirm it actually persisted,
not trusted from the POST response echo alone. Final state was also
independently re-audited end to end (full `tagOwners`, full `grants`,
every device's tags) rather than assumed correct from the apply step.

Babel was already a fully-approved exit node (`0.0.0.0/0`/`::/0` in both
`advertisedRoutes` and `enabledRoutes`, confirmed via the per-device
`/device/{id}/routes` API endpoint — the device-list endpoint's own
`advertisedRoutes` field returns `null` regardless, a real gotcha hit
live).

Joining is via a real tailnet member invite (admin console → Users →
Invite — no API for this part), not a pre-tagged auth key: this is a
permanent relationship, not a scoped one-off, so a real accountable
identity was the right call over a device-only key. Once their device
joins, applying `tag:friend` to it is the one remaining step (an API
call, not an ACL edit).

### Hardening pass 3 (CAA)

One cheap, low-effort addition on top of the existing per-site HSTS header
(which already existed — see the first hardening pass above):

- **CAA DNS record**, restricting which Certificate Authorities may issue
  TLS certs for `mathewcsims.uk` (and, by DNS's normal CAA tree-walk, every
  subdomain that doesn't have its own CAA record — none do). Caddy's
  automatic HTTPS here has no explicit `acme_ca`/`issuer` directive in the
  Caddyfile's global options block, so it runs on Caddy's own default
  behavior: Let's Encrypt first, automatically falling back to ZeroSSL if
  Let's Encrypt is ever unavailable (confirmed from live ACME logs during
  the Owl migration's own cert issuance). A CAA record therefore has to
  authorize **both** CAs, or it silently breaks that fallback resilience.
  Let's Encrypt's own docs give its identifier unambiguously as
  `letsencrypt.org`. ZeroSSL's identifier is less clear-cut — some sources
  say `zerossl.com`, others `sectigo.com` (likely reflecting ZeroSSL's
  2023 move to operate its own root CA after previously chaining through
  Sectigo) — rather than gamble on one, all three `issue` values are
  authorized:
  ```
  @ CAA 0 issue "letsencrypt.org"
  @ CAA 0 issue "sectigo.com"
  @ CAA 0 issue "zerossl.com"
  ```
  CAA `issue` records are purely additive allow-listing (RFC 8659), so
  authorizing an extra identifier doesn't weaken anything — it still
  narrows the CA field from "any of hundreds of public CAs" down to three
  named ones. Added via a small extension to `scripts/dns-digitalocean.sh`
  (new `add-caa`/`list-caa`/`remove-caa` actions, following the script's
  existing Pass-sourced-token pattern — see "Automating this" under Part 3
  above), rather than an ad-hoc API call. Verified propagated via `dig CAA
  mathewcsims.uk @1.1.1.1`, and confirmed Caddy still restarts and serves
  existing certs cleanly afterwards (no CAA-related errors in its logs) —
  not a full re-issuance test, since forcing one on a live site with a
  valid cert isn't worth the disruption; the record's syntax is
  RFC-compliant and authorizes exactly the CAs Caddy actually uses, which
  is what matters.

**Not applied: HSTS preload.** Briefly added a `preload` directive to the
`Strict-Transport-Security` header and then deliberately reverted it —
hstspreload.org's own submission form advises against preloading unless
you're certain every current and future subdomain will only ever be served
over HTTPS, since it's baked into browsers directly (no per-visit
opt-in/opt-out the way plain HSTS has) and takes many browser release
cycles to undo once shipped. Not worth that permanence for a personal
setup where the marginal gain over the existing HSTS header (already
forces HTTPS from the second visit onward) is small.

### Dependency audit (image pins, CVE remediation)

A full sweep of every pinned image across both hosts, plus host-level OS/
Docker packages, checking each against upstream latest and published CVEs.
Most things were already current with no applicable CVE; the following
were bumped and re-pinned:

- **Meilisearch (Karakeep's search backend)**: `v1.11.1` → `v1.49.0`
  (`karakeep/compose.yaml`), fixing CVE-2026-57824 (scoped-key privilege
  escalation) and CVE-2026-57823 (tenant-token info disclosure) — neither
  actually exploitable here since Karakeep only ever uses the full
  `MEILI_MASTER_KEY`, never a scoped key, but 18 months stale regardless.
  **This required a real data migration**, not just a version bump: the
  new engine refused to start against the old on-disk format
  ("Your database version is incompatible with your current engine
  version"). Migrated properly — spun up the old `v1.11.1` image
  read-only against the existing data, triggered a Meilisearch dump via
  its own `/dumps` API, then started `v1.49.0` fresh with
  `--import-dump`, verified the document count matched (22 bookmarks)
  before promoting the migrated directory into the real
  `./meilisearch-data` path Compose manages. The pre-migration data
  directory is kept as `karakeep/meilisearch-data-old-1.11.1/` (gitignored)
  as a safety net — remove it once you're confident search is behaving
  normally.
- **alpine-chrome (Karakeep's screenshot renderer)**: `:123` → `:124`.
  This is as current as this image will ever get — `zenika-hub/alpine-chrome`
  is unmaintained upstream (its own README says so) and stalled here,
  while real Chrome has moved well past this with sandbox-escape CVEs
  fixed only in much newer releases. Since this container renders
  arbitrary bookmarked (attacker-influenced) pages for screenshotting,
  it's worth revisiting with a different actively-maintained
  headless-Chrome image at some point — flagged, not yet acted on.
- **copyparty**: was on the floating `copyparty/ac:latest` tag (no pin at
  all — a reproducibility gap, not a version-currency one, since it
  already resolved to the current upstream release). Pinned to
  `1.20.18@sha256:...` (`copyparty/compose.yaml`).
- **Caddy** (`pi-reverse-proxy/Dockerfile`): both build stages were
  floating (`2-builder-alpine`/`2-alpine`). Pinned to the current stable
  `2.11.4` with digests on both stages. `mholt/caddy-ratelimit` has no
  tagged releases at all (builds only off `master`) — pinned to its
  current HEAD commit for the same reproducibility reason, since there's
  no version number to pin to otherwise. Rebuilt via `docker compose
  build --pull && docker compose up -d` on the Pi; verified the binary
  reports `v2.11.4`, no errors in Caddy's logs, and every site behind it
  still serves correctly afterwards.
- **nginx** (`landing-page/Dockerfile`): floating `nginx:alpine` (which
  tracks nginx's *mainline* branch, not `stable` — worth knowing, since
  "alpine" alone doesn't mean "stable-alpine"). Pinned to the current
  mainline release at the time, `1.31.2-alpine`, with a digest — since
  bumped to `1.31.3-alpine` (3 CVEs) in the 2026-07-19 security pass, see
  below.

Not touched in this pass (flagged as lower-priority "when convenient"
items, not security-urgent): `mysql:8.4.6` (Ghost's DB, a few patches
behind), `ghost:6.50.0`/`ghost/traffic-analytics:1.0.265` (both a little
stale, no CVEs found), and `turboot/nimbus-postgres:18` (floating major
tag — worth a fresh pull next time Nimbus is touched, to pick up 18.4's
pgcrypto fix, CVE-2026-2005). **Update (2026-07-19):** a later security
pass bumped `mysql` to `8.4.10`, `ghost` to `6.53.0`, and the
landing-page `nginx` base to `1.31.3-alpine` (fixing CVE-2026-42533,
CVE-2026-60005, CVE-2026-56434). **Update (2026-07-22):** `nimbus-db`
recreated with a fresh pull of `turboot/nimbus-postgres:18` — was
already on PostgreSQL 18.4 (the version with the pgcrypto fix,
CVE-2026-2005), but the floating tag had a newer image digest available
than what was actually deployed. Then re-pinned `nimbus/compose.yaml`
to that exact digest (was the last image in this repo still on a
floating tag) — now every app here is digest-pinned, so a future
`compose pull` anywhere in the repo can't silently pick up an
unreviewed rebuild. Upstream doesn't publish version-numbered tags for
this image (only `latest`/`18`), so bumping to a newer PostgreSQL point
release means checking Docker Hub for a new digest by hand, same as
before — the difference is just that a stale pin now stays stale
until someone deliberately updates it, rather than drifting silently.

### Weekly CVE pass, 2026-08-02 (316 new findings) — and the method that matters

Trivy reported 316 new findings across 20 images (206 "fixable", 27
unfixed-critical, 83 unfixed-high). **Five images were actually patchable.**
The gap between those two numbers is the useful part of this entry.

**Newer digest ≠ patched. Verify by scanning both.** The obvious move — pull
the current digest for every image and re-pin — was tried and mostly does
nothing. Every candidate was scanned old-vs-new before being kept:

| Image | Fixable before → after | Kept? |
|---|---|---|
| forgejo v16.0.1 → v16.0.2 | 3 → 0 | yes |
| bookstack (rebuild) | 3 → 0 | yes |
| speedtest-tracker (rebuild) | 2 → 0 | yes |
| nimbus (rebuild) | 11 → 3 | yes |
| karakeep (rebuild) | 100 → 82 | yes |
| **caddy** (rebuild) | 8 → 8, CVE lists **byte-identical** | no |
| **apprise** (rebuild) | 13 → 13 | no |
| **valkey** (rebuild) | 0 → 0 | no |
| **memos** → 0.30.0 | 24 → 24 | no |
| **uptime-kuma** 2.4.0 → 2.5.0 | 93 → 93 | no |
| **meilisearch** v1.50 → v1.51 (karakeep) | 0 → 0 | no |

Six of eleven newer images fixed nothing. Deploying them would have been
pure risk — and caddy in particular means rebuilding the Pi's reverse proxy,
which is every app's ingress. **Do not bump on digest-freshness alone.**

**"Fixable" means a patched version exists somewhere, not that it can be
fixed here.** healthlog's `postgres:16.14-alpine` reports 15 fixable HIGHs;
all 15 are Go stdlib CVEs in a helper binary inside the image, waiting on
upstream to rebuild with a newer toolchain. Checked before assuming a
version bump would help: `17-alpine` has the same 15, `18-alpine` has 16,
and the Debian variant is far worse (17 unfixed CRITICAL, 38 unfixed HIGH).
A major-version upgrade would have been a data migration for *negative*
benefit. Alpine stays.

**Deliberately not bumped:** wanderer's Meilisearch (10 fixable HIGHs, all
Alpine base packages). Upstream Wanderer's own compose still ships v1.36.0
on `main`, so a unilateral jump is untested against the app, and Meilisearch
refuses to start against an incompatible on-disk format — 1.36 → 1.51 needs
the dump/import migration documented above for karakeep. Mitigation already
in place: the container publishes no port and is reachable only by
`wanderer-web`/`wanderer-db` on the internal network. Revisit when upstream
moves.

**Three pinning gaps closed** (reproducibility, not CVEs) — the claim above
that "every app here is digest-pinned" had drifted: `healthlog`'s postgres,
`healthlog`'s app image (whose *comment* claimed a digest pin that was not
actually on the image line), and `wanderer`'s meilisearch were all bare tags.

**Deploy note:** `pass-deploy-remote.sh` runs `up -d` with no `pull`, so a
digest change needs `docker compose pull` on the Pi first, otherwise the old
image keeps running and nothing errors. Also `./scripts/pass-deploy.sh
bookstack` fails on the derived item title — it needs the explicit
`BookStack`.

**Verified after deploying:** all six recreated containers healthy, running
images confirmed against the intended digests (note podman reports
`tag@digest` pins as tag-only in `.ImageName` — check `RepoDigests` on the
image instead), and all 21 public endpoints still serving.

### Unfixed CVEs: what is left, and why the mitigations are sufficient

Where a CVE can't be patched, the standing requirement is to say what is
mitigating it and justify that. Done 2026-08-02, by inspecting the running
containers rather than trusting Trivy's package list.

**First: the counts are inflated, in two specific ways.**

1. **The same CVE is counted once per package.** Apprise's "17 unfixed
   CRITICAL" is **5 distinct CVEs** — four Perl ones counted across
   `perl`, `perl-base`, `libperl5.40` and `perl-modules-5.40`, plus one
   OpenSSH client use-after-free.
2. **"Fixable" means a patched version exists upstream, not that it can be
   fixed here.** Nearly all of these need the image maintainer to rebuild.

**Second: one cluster dominates the estate.** CVE-2026-13221, -42496,
-57433 and -8376 are all `perl-base`, and appear in karakeep, uptime-kuma,
apprise, valkey and the Immich images. Perl is in no app's request path in
any of them — it is inherited Debian base furniture. That single cluster
accounts for a large share of the total "unfixed critical" headline.

**Reachability, checked in the running containers:**

| Finding | Verdict | Evidence |
|---|---|---|
| **uptime-kuma** CVE-2026-42010, gnutls auth bypass (CRITICAL, fix published) — *public* | **Not reachable** | `libgnutls30` is linked only by `/usr/bin/curl`, which the app never invokes. Uptime Kuma's monitors run on Node, which uses **OpenSSL 3.5.6**. Confirmed with `ldd` and `apt-cache rdepends` inside the container. Upstream 2.5.0 ships the same unpatched base, so a bump does not help |
| **karakeep** libaom3 / libxml2 / node-tar — *public* | **Reachable** | ffmpeg and librsvg2 decode attacker-supplied media from bookmarked pages. Mitigated, not patched: `cap_drop: ALL`, `mem_limit: 2g`, `pids_limit: 512`, `MAX_ASSET_SIZE_MB=50`, signups disabled, app-level rate limiting plus a Caddy rate-limit zone on the NextAuth callback path |
| **karakeep** mbedtls (CVE-2026-34873/34875) | **Correction to the July note** | July recorded mbedtls as "NOT reachable". It is in fact linked by `/usr/bin/ffmpeg` (via `librist4`), which *is* reachable. The CVEs are in TLS 1.3 handshake paths, and karakeep only ever runs ffmpeg against local files — never RIST/TLS network streams — so the practical verdict is unchanged, but "not present" was the wrong reason |
| **perl-base** cluster, everywhere | **Not reachable** | No app's request path invokes Perl; present as base-image furniture |
| **healthlog** postgres, 15 fixable HIGH | **Not fixable, not worth chasing** | All Go stdlib CVEs in a helper binary. `17-alpine` has the same 15, `18-alpine` 16, Debian far worse. A major upgrade is a data migration for negative benefit |
| **wanderer** meilisearch, 10 fixable HIGH | **Contained** | No published port; reachable only by `wanderer-web`/`wanderer-db` on the internal network. Bump deferred — upstream still ships v1.36.0 and the jump needs a dump/import migration |
| **Immich** (3 images, highest raw counts) | **Contained** | `immich.mathewcsims.uk` is LAN/tailnet-only (`@lan` + `abort` in the Caddyfile), local accounts, no public sharing. Already the most hardened app here — `no-new-privileges` ×5, `mem_limit` ×5, `pids_limit` ×4 |
| **apprise**, **speedtest-tracker**, **bookstack**, **forgejo** | **Contained** | All LAN/tailnet-only at the proxy |

**Hardening gap found and closed.** Auditing the above surfaced something
worse than any single CVE: **uptime-kuma and nimbus are both public and had
no `cap_drop`, no `no-new-privileges` and no resource limits at all** — the
two least-hardened public services in the estate, both on the Pi, which also
runs Caddy and therefore every app's ingress. Both now have
`no-new-privileges`, `cap_drop: ALL` with only the capabilities they need,
and memory/PID limits at roughly 3× observed steady state. This patches
nothing; it caps the blast radius so a crash or resource-exhaustion attempt
stays a contained restart instead of taking the ingress host with it.

**The LAN-only four were done the same day**: `apprise`,
`speedtest-tracker`, `bookstack` and `forgejo` all now have
`no-new-privileges`, `cap_drop: ALL` with only the capabilities they need,
and memory/PID limits at ~4× steady state. Every container in the estate
that faces a hostname is now capped.

**The capability set is dictated by the image, never chosen.** All four run
an init system that starts as root and drops privileges — s6-overlay for the
LSIO images and Forgejo, supervisord for Apprise — so
CHOWN/DAC_OVERRIDE/FOWNER/SETGID/SETUID are mandatory in every case. On top
of that, decided by checking what each actually binds with `netstat` inside
the running container rather than assuming:

- `NET_BIND_SERVICE` for bookstack, speedtest-tracker and forgejo — nginx
  binds :80/:443, and Forgejo's sshd binds **:22 inside** the container (the
  2222 in `ports:` is the host side only). **Not** granted to apprise, which
  listens on :8000.
- `SYS_CHROOT` for forgejo alone — OpenSSH privilege separation chroots its
  unprivileged child. Without it sshd refuses to start **while the web UI
  carries on working**, so git-over-SSH would break silently.

**Verified per app, not just "container is up":** speedtest and bookstack
serving 302 with clean logs; **apprise proven end-to-end by sending a real
notification and confirming both fan-out targets** (ntfy *and* Discord)
delivered it — a health check would not have caught a broken relay; forgejo
web serving 200, `sshd` confirmed running inside the container, an SSH
connection completing the transport handshake, and `git ls-remote` against
the contact-sync store returning refs.

**Cost of that change, recorded honestly:** `cap_drop: ALL` on nimbus caused
~4 minutes of downtime on `dashboard.mathewcsims.uk`. Its image runs nginx
under supervisord, which starts as root, chowns `/var/lib/nginx`, then drops
privileges — so it needs CHOWN, DAC_OVERRIDE, FOWNER, SETGID, SETUID and
NET_BIND_SERVICE. The failure mode is nasty: **Next.js keeps serving on
:3001 so the container looks alive while nginx crash-loops and the app
502s.** Same entrypoint pattern that bit Donetick and Tududi. Add the caps
from the start on any image using supervisord + nginx.

### Branch protection + required CI (GitHub)

Nothing lands on `main` — not even from the repo owner, not even from an
agent operating with the owner's credentials — without going through a PR
whose required checks all pass. Two pieces, added 2026-07-29:

**The checks** (`.github/workflows/ci.yml` — see that file's own comments
for detail). Four required status checks:

- `dependency-review` — fails any PR whose dependency-graph diff
  introduces a package version with a known advisory, at *any* severity.
  This is the PR-gating counterpart to Dependabot alerts, which only scan
  the default branch after a vulnerable dependency has already landed
  (which is exactly how the 15 alerts fixed in PR #4 got in unnoticed).
- `document-viewer` — `npm ci` + full `npm audit --audit-level=low` +
  `tsc --noEmit` + esbuild build for `owl/document-viewer/`. The audit
  step is deliberately stricter than dependency-review: it fails a PR when
  a new advisory has been published against *anything already in* the
  dependency tree, not just when the PR's own diff makes things worse —
  enforcing "the tree is clean", not "no regressions".
- `caddyfile` — builds the Pi's actual custom Caddy image from
  `pi-reverse-proxy/Dockerfile` and runs `caddy validate` against the real
  Caddyfile. The stock caddy image rejects this config outright (no
  `rate_limit` module), so validating against the real image is the only
  meaningful check — and a broken Caddyfile takes down every public
  hostname at once, making it the most dangerous single file in the repo.
- `CodeQL` — GitHub's default-setup code scanning, which was already
  running but previously gated nothing. Its PR check only fails on *new*
  alerts introduced by the PR, so the known pre-existing code-scanning
  findings (deliberately accepted, see the repo's Security tab) don't
  block anything.

**The enforcement**: a repository ruleset ("main protection", visible
under Settings ▸ Rules ▸ Rulesets, created via the API). It requires a PR
before merging (zero required approvals — a solo repo can't self-approve,
so review count would deadlock; the *checks* are the gate, not a
reviewer), requires all four checks above plus an up-to-date branch, and
blocks force-pushes and branch deletion. The bypass list is deliberately
empty: rulesets bind repo admins unless explicitly exempted, which is what
makes "even by me" hold — classic branch protection needed a separate
"include administrators" toggle that was easy to leave off.

**Gotcha to remember**: the ruleset references CI jobs by their `name:`.
Renaming a job in `ci.yml` without updating the ruleset leaves PRs
blocked forever waiting on a check that never reports. The reverse also
holds — the ruleset had to be created *after* the workflow landed on
`main`, since requiring checks that don't exist yet deadlocks every PR
including the one adding them.

Dependabot's own security-update PRs flow through the same gate: they're
ordinary PRs, so they must pass the same four checks before merging.
