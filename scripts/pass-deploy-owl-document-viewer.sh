#!/bin/sh
# Build + deploy the Owl document-viewer (client-side attachment preview,
# see owl/document-viewer/ and SETUP.md's Owl section).
#
# Three steps:
#   1. npm ci + esbuild -> owl/document-viewer/dist/
#   2. bring up the static-file sidecar (owl/document-viewer/compose.yaml)
#   3. write the small bootstrap snippet into Memos' additionalScript field
#      (step 3 only runs if OWL_MEMOS_PAT is set — see
#      deploy_additional_script.py's own header for how to get one; this is
#      a rare, one-time-ish step since additionalScript never needs
#      re-PATCHing just because viewer internals changed, only if the
#      static bundle's own path/filename ever changes).
#
# Usage:
#   ./scripts/pass-deploy-owl-document-viewer.sh
#   OWL_MEMOS_PAT=... ./scripts/pass-deploy-owl-document-viewer.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
DV_DIR="$REPO_ROOT/owl/document-viewer"

echo "Building document-viewer bundle..."
( cd "$DV_DIR" && npm ci && npm run build )

echo "Bringing up static-file sidecar..."
( cd "$DV_DIR" && podman compose up -d )

if [ -n "${OWL_MEMOS_PAT:-}" ]; then
    echo "Deploying additionalScript bootstrap into Memos..."
    SCRIPT_CONTENT='const s=document.createElement("script");s.type="module";s.src="/document-viewer/main.js";document.head.appendChild(s);'
    python3 "$DV_DIR/deploy_additional_script.py" "$SCRIPT_CONTENT"
else
    echo "OWL_MEMOS_PAT not set — skipping additionalScript deploy."
    echo "(Only needed once, or if the bundle's entry filename ever changes."
    echo " See deploy_additional_script.py's header for how to generate a PAT.)"
fi

echo "Done."
