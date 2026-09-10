#!/bin/bash
# PreviewPlayer's seek/pause behaviour, checked without building the whole app.
# `App/` is not an SPM target, so `swift test` cannot reach it; this compiles the
# one file against a standalone harness instead. Run it after touching
# App/PreviewPlayer.swift or App/Views/WaveformView.swift's scrubbing.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -parse-as-library \
    App/PreviewPlayer.swift Tests/AppPlaybackTests/PreviewPlayerChecks.swift \
    -o "$out/preview-player-checks"
"$out/preview-player-checks"
