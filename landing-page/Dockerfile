# LittleLink (https://github.com/sethcottle/littlelink) — a link-in-bio
# style landing page. Genuinely static: nginx serving plain HTML/CSS, no
# backend, no database, no auth, no server-side code at all — confirmed by
# reading the upstream project's own Dockerfile. That makes it about as
# close to zero attack surface as a self-hosted app gets.
#
# There's no published Docker image for this project (upstream ships only a
# Dockerfile you build yourself) — pinned here to an exact tagged release
# fetched at build time, not a moving `main`-branch checkout, so a rebuild
# later doesn't silently pick up unreviewed upstream changes.
#
# The nginx base itself was also floating (`nginx:alpine`, which tracks
# nginx's mainline branch, not `stable`) — pinned to the current mainline
# release (1.31.3) with a digest for the same reproducibility reason.
FROM nginx:1.31.3-alpine@sha256:1dd3048a04f4b76ebd706c1bbb9df7d9d53b4f8253b32ce14467088c9b5ada0f

ARG LITTLELINK_VERSION=3.10.0

RUN apk add --no-cache curl tar && \
    curl -fsSL "https://github.com/sethcottle/littlelink/archive/refs/tags/v${LITTLELINK_VERSION}.tar.gz" -o /tmp/littlelink.tar.gz && \
    rm -rf /usr/share/nginx/html/* && \
    tar -xzf /tmp/littlelink.tar.gz -C /tmp && \
    cp -r /tmp/littlelink-${LITTLELINK_VERSION}/. /usr/share/nginx/html/ && \
    rm -rf /tmp/littlelink.tar.gz "/tmp/littlelink-${LITTLELINK_VERSION}" /usr/share/nginx/html/docker && \
    apk del curl tar

# Overlay our own content on top of upstream's — everything else (CSS,
# icons, reset styles) comes from the pinned release above untouched.
COPY index.html /usr/share/nginx/html/index.html
COPY images/ /usr/share/nginx/html/images/
