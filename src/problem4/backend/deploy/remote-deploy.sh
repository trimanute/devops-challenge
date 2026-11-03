#!/usr/bin/env bash
# Runs ON the EC2 instance (as root) through SSM Run Command. Inputs come from the environment:
#   RELEASE_SHA   commit SHA of the release to activate
#   ARTIFACT_URI  s3://<bucket>/api/<sha>.tar.gz (a matching .sha256 file sits next to it)
#
# Layout:  /opt/api/releases/<sha>/   one directory per release
#          /opt/api/current           symlink to the active release (switched atomically)
#
# Safety: verify checksum, switch symlink atomically, restart, check /healthz reports the new
# version, and put the previous release back if it does not. Exit code tells the pipeline the result.
set -euo pipefail

: "${RELEASE_SHA:?RELEASE_SHA must be set}"
: "${ARTIFACT_URI:?ARTIFACT_URI must be set}"

APP_DIR=/opt/api
RELEASE_DIR="$APP_DIR/releases/$RELEASE_SHA"
PORT="${PORT:-3000}"
KEEP_RELEASES=5

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading $ARTIFACT_URI"
aws s3 cp "$ARTIFACT_URI" "$tmp/release.tar.gz" --only-show-errors
aws s3 cp "$ARTIFACT_URI.sha256" "$tmp/release.sha256" --only-show-errors
expected="$(cut -d' ' -f1 "$tmp/release.sha256")"
echo "$expected  $tmp/release.tar.gz" | sha256sum --check --status || {
  echo "Checksum mismatch, refusing to deploy" >&2
  exit 1
}

previous="$(readlink -f "$APP_DIR/current" || true)"

# Re-deploying the same SHA (retry or rollback target) starts from a clean directory
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
tar -xzf "$tmp/release.tar.gz" -C "$RELEASE_DIR"
chown -R api:api "$RELEASE_DIR"

switch_to() {
  ln -sfn "$1" "$APP_DIR/current.new"
  mv -T "$APP_DIR/current.new" "$APP_DIR/current"
  systemctl restart api
}

healthy() {
  local body
  for _ in $(seq 1 30); do
    if body="$(curl -fsS "http://127.0.0.1:$PORT/healthz" 2>/dev/null)" \
      && grep -q "\"version\":\"$RELEASE_SHA\"" <<<"$body"; then
      return 0
    fi
    sleep 2
  done
  return 1
}

echo "Activating $RELEASE_SHA (previous: ${previous:-none})"
switch_to "$RELEASE_DIR"

if healthy; then
  echo "Release $RELEASE_SHA is healthy"
  # Prune old releases, newest first, never the active one
  # (grep exits 1 when it filters out every line, which is the normal case, hence the || true)
  find "$APP_DIR/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
    | sort -rn | tail -n +$((KEEP_RELEASES + 1)) | cut -d' ' -f2- \
    | { grep -vxF "$(readlink -f "$APP_DIR/current")" || true; } | xargs -r rm -rf
  exit 0
fi

echo "Release $RELEASE_SHA failed its health check" >&2
journalctl -u api --no-pager -n 50 >&2 || true
if [[ -n "$previous" && -d "$previous" ]]; then
  echo "Rolling back to $previous" >&2
  switch_to "$previous"
else
  echo "No previous release to roll back to" >&2
fi
exit 1
