# Caddy has no built-in rate limiting (confirmed against upstream docs/issues —
# it's a deliberately-out-of-scope core feature, left to a plugin). Nimbus
# itself has ZERO brute-force/rate-limit protection anywhere in its own
# codebase (confirmed by reading its source), so without this, its login
# endpoint would be open to unlimited password-guessing. mholt/caddy-ratelimit
# is the standard, actively-maintained module for this. Built in via xcaddy
# rather than downloaded as a binary, so the result is reproducible from this
# Dockerfile and stays on the official Alpine base for the final image.
FROM caddy:2-builder-alpine AS builder

RUN xcaddy build \
	--with github.com/mholt/caddy-ratelimit

FROM caddy:2-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
