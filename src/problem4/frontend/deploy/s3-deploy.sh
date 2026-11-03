#!/usr/bin/env bash
# Publishes a frontend release (built once, stored in the artifact bucket) to the site bucket
# behind CloudFront. Used both for normal deploys and for rollbacks (any previous SHA).
#
# Env: RELEASE_SHA, ARTIFACT_BUCKET, SITE_BUCKET, CLOUDFRONT_DISTRIBUTION_ID
# Assumes the build output has hashed files under assets/ (cache forever) and the entry point is
# index.html (never cached). The pipeline adds version.json so a deploy can be verified.
set -euo pipefail

: "${RELEASE_SHA:?}" "${ARTIFACT_BUCKET:?}" "${SITE_BUCKET:?}" "${CLOUDFRONT_DISTRIBUTION_ID:?}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

uri="s3://$ARTIFACT_BUCKET/web/$RELEASE_SHA.tar.gz"
echo "Downloading $uri"
aws s3 cp "$uri" "$tmp/release.tar.gz" --only-show-errors
aws s3 cp "$uri.sha256" "$tmp/release.sha256" --only-show-errors
expected="$(cut -d' ' -f1 "$tmp/release.sha256")"
echo "$expected  $tmp/release.tar.gz" | sha256sum --check --status || {
  echo "Checksum mismatch, refusing to deploy" >&2
  exit 1
}

dist="$tmp/dist"
mkdir -p "$dist"
tar -xzf "$tmp/release.tar.gz" -C "$dist"
test -f "$dist/index.html" || { echo "index.html missing from release" >&2; exit 1; }
test -f "$dist/version.json" || { echo "version.json missing from release" >&2; exit 1; }

# Order matters: new assets first, so that nobody can load an index.html that points at files
# that are not there yet. Old assets are kept (no --delete) so open tabs and rollbacks keep working.
echo "Uploading hashed assets (immutable)"
if [[ -d "$dist/assets" ]]; then
  aws s3 sync "$dist/assets" "s3://$SITE_BUCKET/assets" \
    --cache-control "public,max-age=31536000,immutable" --only-show-errors
fi

echo "Uploading other static files (short cache)"
aws s3 sync "$dist" "s3://$SITE_BUCKET" \
  --exclude "assets/*" --exclude index.html --exclude version.json \
  --cache-control "public,max-age=300" --only-show-errors

echo "Switching entry point"
aws s3 cp "$dist/version.json" "s3://$SITE_BUCKET/version.json" \
  --cache-control "no-cache" --content-type "application/json" --only-show-errors
aws s3 cp "$dist/index.html" "s3://$SITE_BUCKET/index.html" \
  --cache-control "no-cache" --content-type "text/html; charset=utf-8" --only-show-errors

echo "Invalidating CloudFront"
invalidation_id="$(aws cloudfront create-invalidation \
  --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
  --paths "/" "/index.html" "/version.json" \
  --query Invalidation.Id --output text)"
aws cloudfront wait invalidation-completed \
  --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" --id "$invalidation_id"

echo "Deployed $RELEASE_SHA"
