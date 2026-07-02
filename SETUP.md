# Self-hosted apps — Mac + Raspberry Pi + DrayTek

One Raspberry Pi (Caddy) is the shared internet front door for every app below;
each app is just a podman-compose stack on the Mac. New apps follow the same
recipe — see "Adding another app" near the end.

| App | URL | Runs on | Login |
|-----|-----|---------|-------|
| copyparty | `https://cp.mathewcsims.uk` | Mac `:3923` | `admin` + others, see its section below |
| Memos | `https://prospect-ukri-tus.mathewcsims.uk` | Mac `:5230` | set up on first visit; OAuth planned |
| Nimbus | `https://dashboard.mathewcsims.uk` | **Pi** (not the Mac) | `mat@mathewcsims.uk`, see its section below |

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
4. Bring it up (no cert yet — DNS + router come next):
   ```sh
   docker compose up -d
   docker compose logs -f caddy
   ```

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
docker compose pull && docker compose up -d        # update Caddy
```
After editing the Caddyfile: `docker compose restart caddy`.

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

- Back up **`copyparty/data/`** and **`memos-prospect-ukri-tus/data/`** on the
  Mac (Time Machine covers both if under your home dir). That's all your
  actual data.
- The Pi's `caddy_data` volume holds the TLS certs/account — nice to keep, but
  Caddy re-issues automatically if lost.
- **`nimbus/db/` on the Pi** holds your monitoring config and history — the Pi
  isn't covered by Time Machine, so back this up separately if you care about
  keeping it (losing it just means reconfiguring which services Nimbus tracks,
  not losing anything irreplaceable).

---

## Security notes (internet-facing)

- copyparty has **no anonymous access**: every visitor logs in. Keep it that way.
- The Pi's Caddy serves only `cp.mathewcsims.uk` and refuses any other hostname
  or bare-IP hit — so scanning the public IP reveals nothing.
- **Optional — lock copyparty to the Pi only.** Right now anything on your LAN
  can reach `10.0.1.14:3923` (still needs a login). To restrict it to the Pi,
  add a macOS packet-filter rule allowing :3923 only from `10.0.1.19`, or run
  copyparty with an IP allow-list. Ask me and I'll wire it up.
- Keep both images updated (the `pull && up -d` commands above).
- Use a long unique admin password (already generated in your conf).
