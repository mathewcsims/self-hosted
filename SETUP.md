# Self-hosted apps — Mac + Raspberry Pi + DrayTek

One Raspberry Pi (Caddy) is the shared internet front door for every app below;
each app is just a podman-compose stack on the Mac. New apps follow the same
recipe — see "Adding another app" near the end.

| App | URL | Runs on | Login |
|-----|-----|---------|-------|
| copyparty | `https://cp.mathewcsims.uk` | Mac `:3923` | `admin` + others, see its section below |
| Memos | `https://prospect-ukri-tus.mathewcsims.uk` | Mac `:5230` | set up on first visit; OAuth planned |
| Vikunja | `https://vikunja.mathewcsims.uk` | Mac `:3456` | `mat`, see its section below — no self-registration, ever |
| Nimbus | `https://dashboard.mathewcsims.uk` | **Pi** (not the Mac) | `mat@mathewcsims.uk`, see its section below |
| Speedtest Tracker | `https://speedtest.mathewcsims.uk` | **Pi**, LAN-only | admin credentials set at first boot, see its section below |
| Ghost blog | `https://blog.mathewcsims.uk` | Mac `:2368` | set up on first visit |
| Landing page | `https://mathewcsims.uk` | Mac `:3080` | static site, no login |
| Karakeep | `https://karakeep.mathewcsims.uk` | Mac `:3000` | set up on first visit; signups disabled |
| Apprise API | `https://apprise.mathewcsims.uk` | **Pi**, LAN-only | no login — LAN-gate is the only access control |
| Uptime Kuma | `https://status.mathewcsims.uk` | **Pi** | set up on first visit; 2FA recommended |
| Vikunja webhook relay | `https://vikunja-relay.mathewcsims.uk` | **Pi**, LAN-only | no login — HMAC-signed requests only |
| Kopia backups | `https://backup.mathewcsims.uk` | **Pi**, LAN-only (Mac also backs up, no daemon) | username + password, see its section below |

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
       │             tus, vikunja, blog, karakeep, time    │
       │             (time → oauth2-proxy, not the app     │
       │             directly)                             │
       │     Pi:     dashboard (Nimbus), status (Kuma),    │
       │             speedtest*, apprise*, vikunja-relay*, │
       │             backup* (Kopia)                       │
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
                       vikunja  :3456  (sqlite)
                       blog (Ghost)  :2368  (MySQL)
                       landing-page  :3080  (static)
                       karakeep  :3000  (sqlite + Meilisearch)
                       timetagger's oauth2-proxy  :4180  (TimeTagger
                         itself has NO published port — internal-network
                         only, see the TimeTagger section below)
```

The Pi is the **single front door** for all apps. Because it owns ports 80/443,
Let's Encrypt validation works normally and public URLs are clean, no ports.
Several apps (Nimbus, Speedtest Tracker, Apprise, Uptime Kuma, the Vikunja
webhook relay, Kopia's server) are deliberately Pi-resident rather than
Mac-resident — either
for resilience (the thing telling you something's down shouldn't depend on
the Mac being up) or because they're pure machine-to-machine plumbing with no
reason to cross hosts — see each app's own section below for the (tighter)
networking pattern that comes from Caddy and the app being on the same host.

### File map

`self-hosted/` holds one subfolder per app. Shared, cross-app bits
(`autostart/`, `pi-reverse-proxy/`, `scripts/`, `pf-lockdown/`, this doc) live
at the root. Apps deploy to the **Mac** (`podman compose`) by default; several
deploy to the **Pi** instead (copied over and run with `docker compose`, not
`podman compose` — the Pi runs Docker, not podman) — each app's own section
below says which.

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
| `marque/compose.yaml` | **Mac** | Memos, container `marque` — a third, unrelated instance (private work notes), closed registration, Infomaniak SSO only, fresh install (no migration) |
| `marque/data/` | **Mac** | this instance's notes (sqlite DB + attachments) |
| `marque/marque-logo.svg` | **Mac** | source asset for the instance logo (tracked; deployed as a data URI in Memos' own DB) |
| `marque/marque-theme.css` | **Mac** | source stylesheet for the instance accent theme (tracked; deployed via `additionalStyle` in Memos' own DB) |
| `vikunja/compose.yaml` | **Mac** | Vikunja, pinned to `ghcr.io/go-vikunja/vikunja:2.3.0`; reads secrets from Proton Pass |
| `vikunja/db/` | **Mac** | **your tasks live here** (sqlite) |
| `vikunja/files/` | **Mac** | task attachments |
| `blog/compose.yaml` | **Mac** | Ghost + MySQL + traffic-analytics; reads secrets from Proton Pass |
| `blog/db/` | **Mac** | **Ghost's MySQL datadir** |
| `blog/content/` | **Mac** | **your posts, images, themes live here** |
| `blog/traffic-analytics-data/` | **Mac** | Tinybird-backed analytics data |
| `landing-page/compose.yaml` | **Mac** | static site for the bare apex domain — no secrets, no data dir |
| `karakeep/compose.yaml` | **Mac** | Karakeep + Meilisearch; reads secrets from Proton Pass |
| `karakeep/data/` | **Mac** | **your bookmarks/assets/archives live here** |
| `karakeep/meilisearch-data/` | **Mac** | search index |
| `pi-reverse-proxy/compose.yaml` | **Pi** | Caddy reverse proxy (fronts every app above, plus the LAN-only sites below); also creates the `pi-shared` Docker network |
| `pi-reverse-proxy/Caddyfile` | **Pi** | routing + auto-HTTPS for every hostname |
| `pi-reverse-proxy/.env` | **Pi** | domain, email, Mac IP — gitignored; see `.env.example` |
| `nimbus/compose.yaml` | **Pi** | Nimbus: `nimbus` app + `nimbus-db` (Postgres); joins `pi-shared`; reads secrets from Proton Pass |
| `nimbus/db/` | **Pi** | **your monitoring config/history lives here** (Postgres datadir) |
| `nimbus/uploads/` | **Pi** | Nimbus file uploads (e.g. custom icons) |
| `speedtest-tracker/compose.yaml` | **Pi**, LAN-only | periodic speed tests, charted over time; reads secrets from Proton Pass |
| `speedtest-tracker/config/` | **Pi** | **your speed test history lives here** |
| `apprise/compose.yaml` | **Pi**, LAN-only | generic Discord notification relay for any script to `curl`; no secrets in the compose file itself |
| `apprise/scripts/seed.py` | **Pi** | no-secrets helper invoked by `scripts/pass-seed-apprise.sh` to register the Discord webhook after deploy |
| `apprise/config/` | **Pi** | **the registered notification-target config lives here** |
| `uptime-kuma/compose.yaml` | **Pi** | uptime monitoring + public status page; no secrets — admin account set up via its own first-visit wizard |
| `uptime-kuma/data/` | **Pi** | **your monitors, history, and settings live here** |
| `vikunja-webhook-relay/compose.yaml` + `Dockerfile` + `relay.py` | **Pi**, LAN-only | bridges Vikunja's webhook payload shape to Apprise's `/notify` shape; reads `WEBHOOK_SECRET` from Proton Pass |
| `kopia-server/compose.yaml` + `Dockerfile` + `entrypoint.sh` | **Pi**, LAN-only | Kopia backup server + web UI; reads secrets merged from the "Kopia" and "Backblaze B2" Proton Pass items |
| `kopia-server/config/`, `cache/`, `logs/`, `tmp/` | **Pi** | Kopia's own local state — repository connection, TLS cert, cache. **Not** where your backed-up data lives (that's in B2) |
| `kopia-mac/backup.sh` + `uk.mathewcsims.kopia-mac-backup.plist` | **Mac** | launchd job (no compose project, no persistent daemon) triggering scheduled Kopia snapshots of the Mac's app data + the NAS share |
| `timetagger/compose.yaml` | **Mac** | TimeTagger + oauth2-proxy sidecar (Infomaniak SSO — TimeTagger has no native OAuth); reads secrets from Proton Pass |
| `timetagger/data/` | **Mac** | **your time-tracking entries live here** |
| `timetagger/oauth2-proxy/authenticated-emails.txt` | **Mac** | **gitignored** — the one-address login allowlist, written at deploy time by `pass-deploy-timetagger.sh` |
| `autostart/` | **Mac** | launchd auto-start (all podman containers, every app) |
| `scripts/` | — | deploy tooling that fetches secrets from Proton Pass at deploy time, including `pass-create-kopia-secrets.sh`, `pass-import-b2-credentials.sh`, `pass-import-nas-credentials.sh`, `pass-deploy-kopia-server.sh`, `pass-create-timetagger-secrets.sh`, `pass-deploy-timetagger.sh`, and the DNS automation `dns-digitalocean.sh` / `dns-nextdns.sh` (see "Automating this" under Part 3 above) |
| `pf-lockdown/` | **Mac** | macOS `pf` firewall rules restricting copyparty/Vikunja's published ports to the Pi only, plus SSH Remote Login to the Pi + Tailscale CGNAT range |
| `pi-sshd/` | **Pi** | drop-in `sshd_config.d` file disabling password auth (deployed manually, not via a compose stack) |
| `pi-unattended-upgrades/` | **Pi** | security-only auto-patching config + a daily reboot-required notifier (deployed manually) |
| `pi-fail2ban/` | **Pi** | fail2ban jails (sshd, Caddy-abuse), filters, and ban actions (deployed manually) |

### Known values

| Thing | Value |
|-------|-------|
| Mac LAN IP | `10.0.1.14` |
| Pi LAN IP | `10.0.1.19` |
| Public/WAN IP | `curl -4 ifconfig.me` (static) |
| NAS ("Eddie") | `eddie.nas` / `10.0.1.12`, SMB — see the Kopia section for the `AppleBackups` share |

Give **both the Pi and the Mac a fixed LAN IP** via a DrayTek DHCP reservation
(Part 4) so the forward and proxy config never break.

---

## Secrets management (Proton Pass)

Every app's real secrets live in **Proton Pass**, in a vault named
"Self-Hosted Secrets" (named specifically so it's obvious at a glance
which agent/project a shared vault belongs to, if you end up sharing
others with different agents later) — one custom item per app, each field
named after the env var it holds (e.g. the "Vikunja" item has a
`VIKUNJA_SERVICE_SECRET` field). Nothing is ever written to a `.env` file
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
./scripts/pass-import-env.sh <app-dir>              # e.g. vikunja

# Or for a whole-file secret (currently only copyparty's accounts.conf)
./scripts/pass-import-file.sh <file> <item-title> <field-name>
```

**Deploying an app (the agent side, day to day):**

```
# Mac-hosted apps (vikunja, blog, karakeep, copyparty, landing-page)
./scripts/pass-deploy.sh <app-dir>

# Pi-hosted apps (nimbus, speedtest-tracker) — fetches locally, pipes the
# export + `docker compose up -d` over SSH via stdin, so secret values
# never appear in the SSH command line itself
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
app in this repo (`mc37`, `speedtest`, `apprise`, `vikunja-relay`, `backup`)
needs two separate things to actually be reachable this way, and both were
missing until this was diagnosed directly (bug report → root-caused → fixed
→ verified working, not assumed):

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

With both of these true, a LAN-gated app is reachable over Tailscale exactly
as if you were on the physical LAN — confirmed working end-to-end, not just
theorized.

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
  discipline as Vikunja/Nimbus. Checked against usememos/memos's GitHub
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

---

## Marque (https://marque.mathewcsims.uk)

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

## Nimbus (https://dashboard.mathewcsims.uk) — runs on the Pi, not the Mac

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

## Vikunja (https://vikunja.mathewcsims.uk)

[Vikunja](https://vikunja.io) task management, holding private information —
built with more deliberate hardening than the other apps here, on request.
Single container, sqlite (no separate DB service/password to manage), on the
Mac like copyparty/Memos.

**Image is pinned to `ghcr.io/go-vikunja/vikunja:2.3.0`, NOT the "official"
`docker.io/vikunja/vikunja` the upstream docs point at.** That Docker Hub
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

## Speedtest Tracker (https://speedtest.mathewcsims.uk) — LAN-only, runs on the Pi

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

## Ghost blog (https://blog.mathewcsims.uk)

[Ghost](https://ghost.org) — replaces paid Ghost(Pro) hosting. Two
containers, Mac like copyparty/Memos/Vikunja/Donetick: `ghost` (the app) and
`blog-db` (MySQL 8). Unlike every other app here, Ghost's own docs are
explicit that **MySQL 8 is the only supported database in production** —
sqlite works in dev but isn't QA'd for production, so this needed a real DB
sidecar (same pattern as Nimbus's `nimbus-db`), not the sqlite-in-one-container
approach used elsewhere.

**Image**: `ghost:6.50.0`, pinned to an exact version, not `:latest`.
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
the whole way (ssh stdin → a remote `read` → a here-string into `docker
exec`'s stdin, landing in `apprise/scripts/seed.py`) — into a `POST /add/`
call against the container, registering it under the config key
`self-hosted`. Nothing secret ever touches a Bash argument, an env var, or a
file. Re-run this script any time the webhook is rotated in Pass.

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
   `./scripts/pass-seed-apprise.sh` to register the Discord webhook.
6. Test from a LAN machine:
   `curl -X POST https://apprise.mathewcsims.uk/notify/self-hosted -d 'body=test'`
   — a message should land in Discord within a couple of seconds.

**Notification formatting convention (color, icon, markdown).** The
registered Discord URL carries `?format=markdown&image=yes`
(`scripts/pass-seed-apprise.sh`) — confirmed directly from Apprise's own
`discord.py` source, not assumed: `image=yes` shows a small type icon in
the embed, `format=markdown` lets the `body` use `**bold**`/lists/`` `code`
``, and the embed's sidebar color is set automatically from whatever
`type` value (`info`/`success`/`warning`/`failure`) each `POST
/notify/self-hosted` call includes — this is generic Apprise/Discord
behavior, not something built here. Every notifier in this repo that feeds
this shared endpoint (`pi-fail2ban/notify-apprise.sh`,
`pi-unattended-upgrades/notify-reboot-required.sh`,
`vikunja-webhook-relay/relay.py`) follows the same convention: pick a
`type` matching real severity, prefix the title with a matching emoji
(🚫/✅/⚠️/🔔) for at-a-glance scanning in a channel feed, and send
`format=markdown` with the body. Verified live for all three: ban/unban,
reboot-required, and a signed Vikunja `task.overdue` test event all
rendered with the correct color/icon/markdown in Discord.

**Uptime Kuma does NOT go through this endpoint at all** — it bundles its
own Apprise CLI and shells out to it directly from its own Notification
settings UI (see the Uptime Kuma section below), a structurally separate
path. This formatting convention doesn't apply to Kuma's alerts; that
would need reconfiguring inside Kuma's own UI if wanted.

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

---

## Vikunja webhook relay (https://vikunja-relay.mathewcsims.uk) — LAN-only, runs on the Pi

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

## Kopia backups (https://backup.mathewcsims.uk) — server on the Pi, LAN-only

[Kopia](https://kopia.io) backs up every app's own data — both Mac and Pi —
plus a Time Machine share on the NAS, to Backblaze B2. Client-side encryption
is on by default (not optional, unlike rclone which needs `crypt` bolted on),
snapshots are content-defined-chunked so repeat backups only upload what
changed, and scheduling is automatic.

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
  triggers `kopia snapshot create` daily, mounting the NAS share first.

Both instances writing directly to the same repository is safe — Kopia
designates one `user@hostname` as maintenance owner automatically (the Pi,
since it's always on; the Mac only runs on a schedule, so it's the wrong
host to own garbage collection). The web UI shows snapshots from **both**
hosts, since Kopia stores snapshot manifests in the repository itself, not
per-server — connect any client to the shared repo and it sees everyone's
history.

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
  the SMB share holding the NAS content to back up. Created via
  `scripts/pass-import-nas-credentials.sh`, same interactive-prompt pattern.
  `kopia-mac/backup.sh` fetches this item directly at mount time — see below
  for why, after an earlier Keychain-based approach turned out unreliable.

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

**NAS mount fetches the password from this Pass item directly — not the
macOS Keychain, despite an earlier version of this doc (and this repo)
recommending exactly that.** `mount_smbfs` only ever takes credentials via
its URL argument — there's no piped-input alternative — so a Keychain
lookup was tried first specifically to avoid the password ever appearing in
`ps` output. That worked perfectly when tested by hand in a real Terminal
session (no prompt, no password on any command line) — but the first two
actual overnight `launchd` runs both failed with the exact same
"Authentication error" a plain non-interactive shell gets. macOS's Keychain
access control apparently treats a launchd-spawned process differently from
a Terminal-attached one, and there's no reliable way found to grant a
headless launchd job the same access consistently.

Given `mount_smbfs`'s interface leaves no fully-safe option either way,
`backup.sh` now fetches `NAS_USER`/`NAS_PASSWORD` from Pass and builds the
mount URL directly — accepted, not overlooked: the password is briefly
visible in `ps` output once a day during this run, on a single-user Mac,
which is a materially smaller concern than what a real compromise of this
machine would already expose. The "NAS Eddie" Pass item is the one already
storing this credential either way.

**Other quirks found while actually testing this, now handled in
`backup.sh`:**
- The mount point is `~/nas-mounts/AppleBackups`, not `/Volumes/AppleBackups`
  — macOS only lets a privileged process (Finder's own mount helper,
  effectively) create new directories directly under `/Volumes`; a plain
  `mkdir` there fails with "Permission denied", confirmed directly. A path
  under `$HOME` has no such restriction, so `backup.sh` creates it with a
  normal `mkdir -p` before mounting.
- `backup.sh` auto-logs-in to `pass-cli` the same way the deploy scripts do
  (`SECRET_ACCESS_TOKEN` from the repo-root `.env`) if no session is
  already active, since a scheduled 2am job can't assume one.

**To bring the Pi side up on a fresh machine:**
1. Generate the three Kopia secrets and import the B2 + NAS credentials —
   run these yourself, under your own personal `pass-cli` session:
   ```
   ./scripts/pass-create-kopia-secrets.sh
   ./scripts/pass-import-b2-credentials.sh
   ./scripts/pass-import-nas-credentials.sh
   ```
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
3. Nothing to configure for the NAS mount itself — `backup.sh` fetches
   `NAS_USER`/`NAS_PASSWORD` from the "NAS Eddie" Pass item directly at
   mount time (see above for why this isn't Keychain-based, despite that
   being the more obviously "safe-looking" option at first).
4. Install the LaunchAgent:
   ```
   cp kopia-mac/uk.mathewcsims.kopia-mac-backup.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/uk.mathewcsims.kopia-mac-backup.plist
   ```
   Runs daily at 02:00 — see `kopia-mac/backup.sh` for the exact source
   list. The Kopia repository connection itself needs no Pass access at run
   time (`kopia repository connect`, done once above, persists locally) —
   but the NAS mount step does, auto-logging in via `SECRET_ACCESS_TOKEN`
   from the repo-root `.env` the same way the deploy scripts do, if no
   `pass-cli` session is already active.

**Offline copy on an external HDD:** `scripts/mirror-backup-to-external-drive.sh`
mirrors the entire B2 bucket (already encrypted by Kopia — no extra
encryption needed) onto a drive whenever it's plugged in — no automatic
schedule, since the drive isn't always connected:
```
./scripts/mirror-backup-to-external-drive.sh /Volumes/YourDriveName
```
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

---

## TimeTagger (https://time.mathewcsims.uk)

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

## Adding another app (the general recipe)

Two patterns, depending on where the app runs:

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

**If the app needs a database** (copyparty/Memos didn't, but some apps will):
add it as a second service in the same `compose.yaml`. Give it **no `ports:`**
at all — it only needs to be reached by the app container over the private
compose network (by service name), never by the Pi or the host. Only the app
service gets the LAN-IP-bound port.

### Pi-resident app (Nimbus — for resilience, when the app should stay up even
if the Mac is down)

1. `mkdir self-hosted/<app>` on the Mac (still the source of truth), with its
   own `compose.yaml` — but it **deploys to the Pi**: `scp -r` the folder over
   and run it there with `docker compose`, not `podman compose`.
2. **No `ports:` published at all.** Have the app's service join `pi-shared`
   (defined in `pi-reverse-proxy/compose.yaml`, referenced as `external: true`
   in the new app's `compose.yaml` — see `nimbus/compose.yaml`), and proxy to
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

**Pi (Nimbus):**
```sh
docker compose ps | logs -f | restart | down
# Update: bump the digest in nimbus/compose.yaml first (deliberate, see
# Security notes below — not `pull`+`latest`), then:
docker compose pull nimbus && docker compose up -d
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

---

## Backups

- Back up **`copyparty/data/`**, **`memos-prospect-ukri-tus/data/`**, and
  **`vikunja/db/` + `vikunja/files/`** on the Mac (Time Machine covers all of
  these if under your home dir). That's all your actual data.
- The Pi's `caddy_data` volume holds the TLS certs/account — nice to keep, but
  Caddy re-issues automatically if lost.
- **`nimbus/db/` on the Pi** holds your monitoring config and history — the Pi
  isn't covered by Time Machine, so back this up separately if you care about
  keeping it (losing it just means reconfiguring which services Nimbus tracks,
  not losing anything irreplaceable).

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

### Restricting LAN-only ports (copyparty, Vikunja)

Every Mac-hosted app publishes its port bound to `10.0.1.14`, reachable by
any device on the LAN, not just the Pi's Caddy — intended to be reached
only via Caddy's TLS + rate-limiting, with direct LAN access as an
unnecessary (if still login-gated) extra path in. Fixed for copyparty and
Vikunja specifically via a macOS `pf` firewall rule — see `pf-lockdown/`.

**Why not fix this at the app level instead?** Tried copyparty's own
`--ipa` (IP allow-list) option first — it doesn't work here. Behind
podman's published-port NAT, copyparty only ever sees podman's *internal
gateway IP* as the connection source, never the real LAN IP (confirmed
against [copyparty issue
#1109](https://github.com/9001/copyparty/issues/1109)) — setting `ipa` to
the Pi's IP blocked the Pi too, along with everyone else. Vikunja has no
equivalent option at all. A firewall-layer rule was the only approach that
actually works for either.

**What the rule does:** `pf-lockdown/com.mathewcsims.lan-lockdown` allows
TCP to `10.0.1.14` ports `3923`/`3456` from `10.0.1.19` (the Pi) only, and
blocks everyone else — scoped to exactly those two ports; nothing else on
this Mac is affected.

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

This runs the reload script (which enables `pf` if it isn't already, then
loads the ruleset) at every boot — no per-reboot action needed after this.

**Verify it worked:**

```
sudo pfctl -a com.mathewcsims.lan-lockdown -s rules   # confirm the rules loaded
curl http://10.0.1.14:3923/       # from the Mac itself — should now be blocked
ssh mathew@babel 'curl http://10.0.1.14:3923/'   # from the Pi — should still work
```

### Hardening pass (copyparty, Nimbus, Caddy, Memos)

Applied across the board, on top of what each app section above already
documents (Vikunja's app-level hardening, Nimbus's OIDC, Memos's registration
policy, etc.):

- **Reusable security headers, now on every site, not just Vikunja.**
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
  get an identical 404 whether a private path exists or not (no compatible
  with WebDAV, which this setup doesn't use). Also made the already-active
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
  Ban/unban events notify via the same Apprise pipe as everything else in
  this repo. Verified live end-to-end: the filter regex correctly matches
  a synthetic scanner-shaped log line; feeding two real scanner-path hits
  from a test IP through the actual monitored log file triggered a real
  ban (confirmed in both `fail2ban-client status caddy-abuse` and
  `iptables -L f2b-caddy-abuse`), then cleanly unbanned.

**Manual action items — out of scope for this repo, worth doing
separately:**
1. Check the DrayTek Vigor2866's port-forwarding table directly to confirm
   WAN port 22 isn't forwarded to the Pi (only 80/443 are documented).
2. Review the Tailscale ACL policy in the Tailscale admin console — it
   governs which tailnet peers can reach either host's SSH port (and
   everything else Tailscale-reachable), and isn't visible or editable
   from either machine.

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
  mainline release, `1.31.2-alpine`, with a digest.

Not touched in this pass (flagged as lower-priority "when convenient"
items, not security-urgent): `mysql:8.4.6` (Ghost's DB, a few patches
behind), `ghost:6.50.0`/`ghost/traffic-analytics:1.0.265` (both a little
stale, no CVEs found), and `turboot/nimbus-postgres:18` (floating major
tag — worth a fresh pull next time Nimbus is touched, to pick up 18.4's
pgcrypto fix, CVE-2026-2005).
