#!/usr/bin/env bash
# Builds the immutable release artifact: dist/<sha>.tar.gz plus its sha256 file.
# The same artifact is deployed to staging and then production (build once, deploy many).
set -euo pipefail

: "${RELEASE_SHA:?RELEASE_SHA must be set}"

cd "$(dirname "$0")/.."

out=dist
rm -rf "$out"
mkdir -p "$out/stage"

cp -r src package.json package-lock.json "$out/stage/"
echo "RELEASE_SHA=$RELEASE_SHA" > "$out/stage/release.env"

# Production dependencies are bundled so instances never run npm install (no registry access needed on EC2).
# --ignore-scripts: do not run third party install scripts during the build.
(cd "$out/stage" && npm ci --omit=dev --ignore-scripts)

tar -czf "$out/$RELEASE_SHA.tar.gz" -C "$out/stage" .
rm -rf "$out/stage"

cd "$out"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$RELEASE_SHA.tar.gz" > "$RELEASE_SHA.tar.gz.sha256"
else
  shasum -a 256 "$RELEASE_SHA.tar.gz" > "$RELEASE_SHA.tar.gz.sha256"
fi

ls -l
