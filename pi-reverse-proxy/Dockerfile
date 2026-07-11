# Caddy has no built-in rate limiting (confirmed against upstream docs/issues —
# it's a deliberately-out-of-scope core feature, left to a plugin). Nimbus
# itself has ZERO brute-force/rate-limit protection anywhere in its own
# codebase (confirmed by reading its source), so without this, its login
# endpoint would be open to unlimited password-guessing. mholt/caddy-ratelimit
# is the standard, actively-maintained module for this. Built in via xcaddy
# rather than downloaded as a binary, so the result is reproducible from this
# Dockerfile and stays on the official Alpine base for the final image.
#
# Both stages were previously floating (`2-builder-alpine`/`2-alpine`), so a
# rebuild could silently pick up a new Caddy patch with no changelog review.
# Pinned to the current stable release (2.11.4) with digests instead.
# caddy-ratelimit itself has no tagged releases upstream (builds only off
# `master`) — pinned to its current HEAD commit for the same reproducibility
# reason, since there's no version to pin to otherwise.
FROM caddy:2.11.4-builder-alpine@sha256:8e89605351333ad2cc2f3bcc95275a2ccc427f88914050e86a5fde0fd77a63c4 AS builder

RUN xcaddy build \
	--with github.com/mholt/caddy-ratelimit@5625512f24f6f59d6f64fb3aafe5eecff0b286db

FROM caddy:2.11.4-alpine@sha256:1172d4213087d3fc30bafc7ff2c2896180eb0c41ff7f75f315568fb36cabdcba

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
