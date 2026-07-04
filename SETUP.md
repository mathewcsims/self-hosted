# Self-hosted apps — Mac + Raspberry Pi + DrayTek

One Raspberry Pi (Caddy) is the shared internet front door for every app below;
each app is just a podman-compose stack on the Mac. New apps follow the same
recipe — see "Adding another app" near the end.

| App | URL | Runs on | Login |
|-----|-----|---------|-------|
| copyparty | `https://cp.mathewcsims.uk` | Mac `:3923` | `admin` + others, see its section below |
| Memos | `https://prospect-ukri-tus.mathewcsims.uk` | Mac `:5230` | set up on first visit; OAuth planned |
| Nimbus | `https://dashboard.mathewcsims.uk` | **Pi** (not the Mac) | `mat@mathewcsims.uk`, see its section below |
| Vikunja | `https://vikunja.mathewcsims.uk` | Mac `:3456` | `mat`, see its section below — no self-registration, ever |

## Architecture

```
                  your single static public IP
                             │
               DrayTek Vigor2866  (WAN 80/443)
                             │  forwarded to the Pi (10.0.1.19)
                             ▼
       ┌──────────────────────────────────────────────────┐
       │  Raspberry Pi 10.0.1.19                           │
       │  • Caddy: terminates HTTPS (Let's Encrypt, auto)  │
       │  • routes by hostname:                            │
       │      cp.mathewcsims.uk                → Mac:3923  │
       │      prospect-ukri-tus.mathewcsims.uk → Mac:5230  │
       │      vikunja.mathewcsims.uk           → Mac:3456  │
       │      dashboard.mathewcsims.uk         → Nimbus,   │
       │        a SEPARATE compose stack ALSO on this Pi,  │
       │        reached by container name over a shared    │
       │        Docker network — no host port published    │
       │  • refuses any other hostname / bare IP           │
       └──────────────────────────┬───────────────────────┘
                                  │ LAN http (one hop per Mac app)
                                  ▼
                     Mac 10.0.1.14 — one podman-compose
                     stack per app, each its own folder:
                       copyparty  :3923  (data on disk)
                       memos-prospect-ukri-tus  :5230  (sqlite)
                       vikunja  :3456  (sqlite)
```

The Pi is the **single front door** for all apps. Because it owns ports 80/443,
Let's Encrypt validation works normally and public URLs are clean, no ports.
Nimbus is deliberately Pi-resident (not Mac-resident like the others) so the
monitoring dashboard itself stays up if the Mac goes down for maintenance —
see its section below for the different (and tighter) networking pattern that
comes from Caddy and the monitored app being on the same host.

### File map

`self-hosted/` holds one subfolder per app. Shared, cross-app bits
(`autostart/`, `pi-reverse-proxy/`, this doc) live at the root. Everything
deploys to the **Mac** except `pi-reverse-proxy/` and `nimbus/`, which deploy
to the **Pi** (copied over and run with `docker compose`, not `podman compose`
— the Pi runs Docker, not podman).

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
| `vikunja/compose.yaml` | **Mac** | Vikunja, pinned to `ghcr.io/go-vikunja/vikunja:2.3.0`; reads secrets from `.env` |
| `vikunja/.env` | **Mac** | **real service secret — gitignored**; see `.env.example` |
| `vikunja/db/` | **Mac** | **your tasks live here** (sqlite) |
| `vikunja/files/` | **Mac** | task attachments |
| `pi-reverse-proxy/compose.yaml` | **Pi** | Caddy reverse proxy (fronts every app above, plus the LAN-only router-admin site); also creates the `pi-shared` Docker network |
| `pi-reverse-proxy/Caddyfile` | **Pi** | routing + auto-HTTPS for every hostname |
| `pi-reverse-proxy/.env` | **Pi** | domain, email, Mac IP — gitignored; see `.env.example` |
| `nimbus/compose.yaml` | **Pi** | Nimbus: `nimbus` app + `nimbus-db` (Postgres); joins `pi-shared`; reads secrets from `.env` |
| `nimbus/.env` | **Pi** | **real DB/JWT/admin/OIDC secrets — gitignored**; see `.env.example` |
| `nimbus/db/` | **Pi** | **your monitoring config/history lives here** (Postgres datadir) |
| `nimbus/uploads/` | **Pi** | Nimbus file uploads (e.g. custom icons) |
| `autostart/` | **Mac** | launchd auto-start (all podman containers, every app) |

### Known values

| Thing | Value |
|-------|-------|
| Mac LAN IP | `10.0.1.14` |
| Pi LAN IP | `10.0.1.19` |
| Public/WAN IP | `curl -4 ifconfig.me` (static) |

Give **both the Pi and the Mac a fixed LAN IP** via a DrayTek DHCP reservation
(Part 4) so the forward and proxy config never break.

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
Pi and just works. From *inside* your LAN it may time out, because many routers
(including the DrayTek by default here) don't "hairpin" a connection to your own
public IP back inside. Cleanest fix — make the name resolve straight to the Pi
for LAN clients:

**DrayTek ▸ Applications ▸ LAN DNS / DNS Cache** → add a profile:
- Domain name: `cp.mathewcsims.uk`
- IP address: `10.0.1.19` (the Pi)

Now LAN devices reach the Pi directly (valid cert, no router round-trip), while
the outside world still uses the public IP.

---

## Router admin via mc37.mathewcsims.uk (LAN-only)

A second Caddy site proxies `https://mc37.mathewcsims.uk` → the DrayTek admin at
`https://10.0.1.1:8443`, but **only for private/LAN source IPs** (a
`remote_ip private_ranges` guard) — internet clients are dropped. To make it work:

1. **Public A record** (registrar): `mc37` → your WAN IP. Needed only so Caddy
   can obtain a Let's Encrypt cert; actual access is still blocked to non-LAN.
2. **DrayTek LAN DNS** (Applications ▸ LAN DNS / DNS Cache): `mc37.mathewcsims.uk`
   → `10.0.1.19`. This makes LAN devices reach the Pi directly, so their source
   IP is private and passes the guard. (LAN devices must use the DrayTek as their
   DNS resolver for this to apply.)
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
4. **DrayTek LAN DNS** (Applications ▸ LAN DNS / DNS Cache): add
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
4. **DrayTek LAN DNS**: add `dashboard.mathewcsims.uk` → `10.0.1.19`.
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
4. **DNS:** a wildcard record already covers new subdomains here — check
   `python3 -c "import socket; print(socket.gethostbyname('yourdomain'))"`
   resolves before assuming you need to add anything at the registrar.
5. **DrayTek LAN DNS**: add `vikunja.mathewcsims.uk` → `10.0.1.19`, same as
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
DrayTek router admin): a real public DNS record and Caddy-issued Let's
Encrypt cert exist (a wildcard already covers new subdomains here — nothing
to add at the registrar), but `pi-reverse-proxy/Caddyfile`'s
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
3. **DNS:** nothing to add — the existing wildcard record covers this
   subdomain already.
4. **DrayTek LAN DNS** (Applications ▸ LAN DNS / DNS Cache): add
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
4. **DNS:** nothing to add — the existing wildcard record covers this
   subdomain (this domain previously had an explicit record pointing at
   Ghost(Pro)'s hosting from before the migration; it turned out to already
   be repointed by the time of deployment, so no separate action was needed
   here, but don't assume that's true for every domain being migrated onto
   this stack later).
5. **DrayTek LAN DNS**: add `blog.mathewcsims.uk` → `10.0.1.19`, same as
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
app here.** The existing wildcard record covers `*.mathewcsims.uk`
automatically, as it has for every other app in this repo, but a wildcard
does not cover the bare apex (`mathewcsims.uk` itself) — that needed its own
explicit A record, pointed directly at the Pi's WAN IP by the domain owner
rather than through anything in this repo.

**To bring it up:**
1. **Mac:** `cd landing-page && podman compose up -d` — starts on
   `10.0.1.14:3080`.
2. **Pi:** copy the updated `pi-reverse-proxy/Caddyfile` over and
   `docker compose restart caddy`.
3. **DNS:** an explicit A record for the bare domain, not the wildcard —
   see above.
4. **DrayTek LAN DNS**: add `mathewcsims.uk` → `10.0.1.19`, same as every
   other app.

---

## ArchiveBox (https://archivebox.mathewcsims.uk)

[ArchiveBox](https://github.com/ArchiveBox/ArchiveBox) — self-hosted web
archiving (wget mirror, screenshot, PDF, headless-Chrome DOM dump, media via
yt-dlp, etc. per URL). Fully private: no anonymous browsing, no anonymous
submission, private-by-default snapshots.

**Image, pinned:** no stable numbered release exists right now — the project
is permanently on an rc train for its 0.9.x/0.10 rewrite. Checked GitHub
security advisories directly: a critical RCE (CVE-2026-42601 /
GHSA-3h23-7824-pj8r, CVSS 9.8 — unvalidated `config` JSON on the `/add`
endpoint, pre-auth when `PUBLIC_ADD_VIEW=True`) affects `<= 0.8.6rc0`; pinned
to `0.9.35rc102`, well past that fix boundary, and to the exact tag (not the
floating `dev` tag the official docker-compose.yml defaults to) so an
upgrade is a deliberate decision.

**Hardening decisions made (see `archivebox/compose.yaml` for the full
reasoning):**
- `PUBLIC_INDEX=False`, `PUBLIC_ADD_VIEW=False`, `PERMISSIONS=private` — no
  anonymous access to anything, and this closes the CVE above regardless.
- `ARCHIVEDOTORG_ENABLED=False` — ArchiveBox's own security docs warn URLs
  (including embedded secret tokens) get submitted to archive.org
  *unfiltered* otherwise, defeating the point of a private archive.
- `SERVER_SECURITY_MODE=safe-subdomains-fullreplay` — each archived snapshot
  is served from its own subdomain (e.g.
  `web.archivebox.mathewcsims.uk`, random per-snapshot ones for replay),
  scoping admin session cookies away from archived content entirely.
  Originally shipped with `safe-onedomain-nojsreplay` (single domain, JS
  disabled on replay) to avoid the wildcard DNS/cert work below — reversed
  after actually reading ArchiveBox's own source
  (`config/common.py`/`system_warnings_banner`): it flags *every*
  non-subdomain mode as "unsafe" in its own UI, onedomain-nojsreplay
  included, because same-origin cookies still get attached to same-origin
  requests regardless of whether JS executes — disabling JS narrows the
  risk but doesn't eliminate it. Needs a `*.archivebox.mathewcsims.uk`
  wildcard DNS record (see below) and DNS-01 cert issuance, since
  Let's Encrypt can't validate a wildcard via the HTTP-01 challenge every
  other site here uses.
- Caddy-side rate limit on `/admin/login/*` — ArchiveBox has no built-in
  login throttling at all (unlike Ghost/Vikunja elsewhere in this repo).

**Storage: NAS over NFS, not local disk.** ArchiveBox's own docs are
explicit that `data/index.sqlite3` must stay on a local, fsync-capable
filesystem (SQLite's WAL locking doesn't work reliably over NFS/SMB), while
`data/archive/` (the bulk content — screenshots, WARCs, media, PDFs) is
officially supported on slower remote storage. So `./data` (this Mac's SSD)
holds the index, and `/data/archive` is bind-mounted to a WD My Cloud EX2
Ultra NFS export instead.

That NFS mount happens **inside the podman-machine VM itself**, not on the
macOS host — see `archivebox/nfs-mount/`. First attempt mounted NFS on the
Mac host under `/private` (one of podman-machine's default virtiofs shares
into the VM) and relied on virtiofs to pass it through; confirmed empirically
that this doesn't work reliably — virtiofs does not cross a submount
boundary, so the VM's mount table listed the share but every file operation
through it failed with ENOENT. Mounting natively inside the VM's own Linux
kernel (Fedora CoreOS, which already ships `nfs-utils` and the kernel
modules) sidesteps that entirely, and is one less moving part than a
host-side LaunchDaemon.

The NAS applies `root_squash` (writes from the VM's root user land owned by
a NAS-side mapped UID/GID, not root) — the export root itself is
pre-existing and owned by real root, so ArchiveBox's own init (which chmods
whatever directory it's given) fails against it with `EPERM`. Fixed by
bind-mounting a *subdirectory* of the NFS mount instead of the export root:
that subdirectory is created by the mount script (so it's owned by the same
mapped UID ArchiveBox itself is squashed to), and chmod-ing something you
own always works, root_squash or not.

**To bring it up on a fresh machine:**
1. **NAS:** enable NFS in the WD dashboard (Settings → Network → NFS
   Service), then on the target share (Shares → *share* → NFS Access → On),
   restrict the allowed IP to the Mac's LAN IP specifically (not `*`).
2. **Podman VM:** copy `archivebox/nfs-mount/archivebox-nfs-mount.sh` and
   `archivebox-nfs-mount.service` into the VM and enable the service:
   ```
   podman machine ssh podman-machine-default -- 'cat > /etc/archivebox-nfs-mount.sh' < archivebox/nfs-mount/archivebox-nfs-mount.sh
   podman machine ssh podman-machine-default -- 'chmod +x /etc/archivebox-nfs-mount.sh'
   podman machine ssh podman-machine-default -- 'cat > /etc/systemd/system/archivebox-nfs-mount.service' < archivebox/nfs-mount/archivebox-nfs-mount.service
   podman machine ssh podman-machine-default -- 'systemctl daemon-reload && systemctl enable --now archivebox-nfs-mount.service'
   ```
   This runs automatically on every `podman machine start` from then on —
   no per-boot action needed on the Mac side.
3. **Mac:** `cd archivebox && podman compose up -d` — starts on
   `10.0.1.14:8000`. `ADMIN_USERNAME`/`ADMIN_PASSWORD` in `.env` bootstrap
   the one superuser account on first run only.
4. **DNS:** this app needs a genuine wildcard record,
   `*.archivebox.mathewcsims.uk` → the Pi's WAN IP — unlike every other app
   in this repo. (Correction to earlier notes elsewhere in this file: there
   is no actual `*.mathewcsims.uk` wildcard covering everything — checked
   directly via the DigitalOcean API, and every other hostname here has its
   own individually-added A record. That's fine for apps with one fixed
   hostname, but ArchiveBox generates unpredictable per-snapshot subdomains,
   which genuinely can't be enumerated in advance, hence the real wildcard.)
5. **Caddy build:** the `archivebox.mathewcsims.uk` block needs DNS-01 cert
   issuance for the wildcard, which needs the `caddy-dns/digitalocean`
   module (already added to `pi-reverse-proxy/Dockerfile`) and a
   `DO_API_TOKEN` in `pi-reverse-proxy/.env` (DigitalOcean → Settings → API
   → Generate New Token, DNS scope). Copy the updated Caddyfile/Dockerfile/
   compose.yaml over, then `docker compose build && docker compose up -d`
   on the Pi (a `docker compose restart` alone won't pick up the new module
   — the image itself needs rebuilding).

**Known cosmetic bug, not a security issue:** `libdns/digitalocean`'s
`idFromRecord` (confirmed by reading its source) expects its own custom
record type when deleting the temporary ACME challenge TXT record, but
Caddy's cert-renewal cleanup passes back a generic one — the type
assertion fails silently, leaving a stray `_acme-challenge.archivebox` TXT
record in DigitalOcean DNS after every renewal. Cert issuance itself always
succeeds regardless; this is purely leftover DNS clutter, harmless, and not
worth automating cleanup for given it only happens ~6x/year. Delete it
manually via the DO dashboard/API if it ever bothers you.

**Offsite backup:** not set up yet (deliberately deferred) — the NAS is the
only copy right now. A nightly `rclone sync` from the NAS archive folder to
something like Backblaze B2 would add real offsite redundancy without ever
writing live through a cloud FUSE mount; revisit once there's enough
archived content to make that worth setting up.

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
6. DNS: public `A` record (registrar) for cert issuance, plus a DrayTek LAN DNS
   entry so LAN devices resolve straight to the Pi.
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
   hostname; registrar `A` record + DrayTek LAN DNS entry).
5. Auto-start: nothing to add — Docker's `restart: unless-stopped` + Docker
   starting at boot (Pi default) covers it, same as Caddy. The Mac's
   `autostart/` launchd agent is irrelevant to anything Pi-resident.

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
- **Optional — lock copyparty/Vikunja to the Pi only.** Right now anything on
  your LAN can reach `10.0.1.14:3923` or `:3456` directly (still needs a
  login). To restrict either to the Pi only, add a macOS packet-filter rule
  allowing that port only from `10.0.1.19`, or run the app with its own IP
  allow-list. Ask me and I'll wire it up.
- Keep every image updated (the `pull && up -d` commands above) — but review
  before pulling: copyparty, Nimbus, and Vikunja are all pinned to an exact
  tag/digest deliberately (see each app's compose.yaml), so an upgrade is a
  conscious decision, not something that happens silently on a routine
  restart.
- Use a long unique admin password per app (already generated where relevant).

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
