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
FROM nginx:alpine

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
# TODO: once a real avatar image is supplied, add ./images/avatar.png +
# avatar@2x.png here and add `COPY images/ /usr/share/nginx/html/images/`
# below — index.html currently points at upstream's own placeholder image
# until then.
COPY index.html /usr/share/nginx/html/index.html
