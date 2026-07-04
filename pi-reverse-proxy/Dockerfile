# Caddy has no built-in rate limiting (confirmed against upstream docs/issues —
# it's a deliberately-out-of-scope core feature, left to a plugin). Nimbus
# itself has ZERO brute-force/rate-limit protection anywhere in its own
# codebase (confirmed by reading its source), so without this, its login
# endpoint would be open to unlimited password-guessing. mholt/caddy-ratelimit
# is the standard, actively-maintained module for this. Built in via xcaddy
# rather than downloaded as a binary, so the result is reproducible from this
# Dockerfile and stays on the official Alpine base for the final image.
#
# caddy-dns/digitalocean: needed for the archivebox.mathewcsims.uk wildcard
# cert (DNS-01 challenge, the only way to get a wildcard cert — HTTP-01,
# used everywhere else in this Caddyfile, can't validate one). DNS is
# managed at DigitalOcean; this module lets Caddy create/clean up the
# challenge TXT record itself via their API.
FROM caddy:2-builder-alpine AS builder

RUN xcaddy build \
	--with github.com/mholt/caddy-ratelimit \
	--with github.com/caddy-dns/digitalocean

FROM caddy:2-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
