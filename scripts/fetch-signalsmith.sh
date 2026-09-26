#!/usr/bin/env bash
# Vendors signalsmith-stretch + signalsmith-linear headers into
# Sources/CSignalsmithStretch/vendor/. Both are MIT.
#
# The headers are COMMITTED (like Sources/CSherpaOnnx/include). This script
# exists to make the provenance reproducible and the version bump a one-liner,
# not because the build fetches anything.
set -euo pipefail

STRETCH_COMMIT=57b93f4e9206a089a45387eaa39bdc9f310d3308   # v1.3.2
LINEAR_COMMIT=547f4a6c55b4243191a9180f39849d67cc66aa0d

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/CSignalsmithStretch/vendor"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git clone --quiet https://github.com/Signalsmith-Audio/signalsmith-stretch.git "$TMP/stretch"
git -C "$TMP/stretch" checkout --quiet "$STRETCH_COMMIT"
git clone --quiet https://github.com/Signalsmith-Audio/linear.git "$TMP/linear"
git -C "$TMP/linear" checkout --quiet "$LINEAR_COMMIT"

rm -rf "$DEST"
mkdir -p "$DEST/signalsmith-linear"
cp "$TMP/stretch/signalsmith-stretch.h" "$DEST/"
cp "$TMP/stretch/LICENSE.txt" "$DEST/LICENSE-signalsmith-stretch.txt"
cp "$TMP/linear"/*.h "$DEST/signalsmith-linear/"
cp -R "$TMP/linear/platform" "$DEST/signalsmith-linear/"
cp "$TMP/linear/LICENSE.txt" "$DEST/signalsmith-linear/LICENSE.txt"

echo "vendored signalsmith-stretch @ $STRETCH_COMMIT"
echo "vendored signalsmith-linear  @ $LINEAR_COMMIT"
