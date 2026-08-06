# Etherpad + plugins for pads.mathewcsims.uk.
#
# A custom image is needed because Etherpad installs plugins at BUILD time —
# there is no runtime plugin env var on the official image (the ETHERPAD_PLUGINS
# build arg only exists when building Etherpad from source). Deriving from the
# published image and running Etherpad's own supported installer is lighter than
# a source build and keeps us on the upstream release. Same approach as
# ../pi-reverse-proxy/Dockerfile, which builds Caddy with an extra module.
#
# Plugins, and why each one:
#   ep_padlist2   — the pad directory at /list. Without it Etherpad has no way
#                   to see what pads exist; you must already know the URL.
#   ep_hash_auth  — lets the `users` block in settings.json hold bcrypt hashes
#                   instead of plaintext passwords, and adds a filesystem user
#                   store (see settings.json) so accounts can be added without
#                   editing config or restarting.
#
# Deliberately NOT installed:
#   INSTALL_SOFFICE — pulls in LibreOffice for DOC/PDF export. Large, and this
#                   instance is for authoring, not producing Office files.
#   ep_comments_page — not wanted here (see the plan); it can be added later,
#                   though note that means a rebuild, since plugins are
#                   build-time.
#
# Trivy picks this image up automatically from the FROM line below (scan.py
# derives its image list from every compose.yaml `image:` and every Dockerfile
# `FROM`), which is why the tag AND digest are both pinned.
FROM docker.io/etherpad/etherpad:3.3.3@sha256:6020e7b57f4b17389ef000a5a2b04e6ab3ea6659c7c7ab83b81587010fa58be4

WORKDIR /opt/etherpad-lite

# `pnpm run install-plugins` is Etherpad 3's supported installer (it calls
# linkInstaller.installPlugin internally) — not a raw `pnpm add`, which would
# fight the pnpm workspace this image is built around.
RUN pnpm run install-plugins ep_padlist2 ep_hash_auth
