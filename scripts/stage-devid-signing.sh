#!/usr/bin/env bash
# Stages Developer ID signing + notarization material from Infisical into a
# dedicated local keychain and a set of env vars, for `fastlane build_notarized`.
#
# This is intentionally separate from the Mac App Store path (`build_pkg`),
# which is staged by the external ship.sh/infisical-macos-signing.sh tooling
# (not in this repo). That tooling doesn't know about Developer ID material —
# this script fills that gap for direct-distribution (GitHub release) builds.
#
# Requires: the `infisical` CLI, logged in with access to the
# gloam-voice-studio-macos-signing path (ask a teammate who's already set up
# to add you, or use an Infisical machine identity — see README below).
#
# Usage: source this script (not execute) so the exported env vars survive
# into your shell / into the fastlane invocation:
#   source scripts/stage-devid-signing.sh
#   bundle exec fastlane build_notarized
set -euo pipefail

INFISICAL_DOMAIN="https://infisical.tinytrashlabs.com"
INFISICAL_PROJECT_ID="d5b50b4d-a82b-4cc7-b52c-7b375b31f7ac"
INFISICAL_PATH="/gloam-voice-studio-macos-signing"
INFISICAL_ENV="prod"

STAGE_DIR="$(mktemp -d /tmp/gloam-devid-stage.XXXXXX)"
KEYCHAIN_PATH="${MAC_DEVID_KEYCHAIN:-$HOME/Library/Keychains/gloam-devid-build.keychain-db}"
KEYCHAIN_PASSWORD="$(openssl rand -base64 24)"

infisical_get() {
  infisical secrets get "$1" \
    --path "$INFISICAL_PATH" --projectId "$INFISICAL_PROJECT_ID" \
    --env "$INFISICAL_ENV" --domain "$INFISICAL_DOMAIN" --plain 2>/dev/null
}

echo "Staging Developer ID + notarization material from Infisical ($INFISICAL_PATH, env=$INFISICAL_ENV)..."

# --- Developer ID Application identity (base64 p12 + password) -------------
infisical_get MAC_DEVELOPER_ID_APPLICATION_CERT_P12 | base64 -d > "$STAGE_DIR/devid.p12"
P12_PASSWORD="$(infisical_get MAC_DEVELOPER_ID_APPLICATION_CERT_PASSWORD)"

# A dedicated keychain (not login.keychain) so this works headlessly in CI
# and never pollutes/depends on a developer's personal keychain contents.
# Always start fresh: KEYCHAIN_PASSWORD is regenerated every run, so a
# leftover keychain file from a prior run would have a different password,
# breaking unlock/import ACL updates on the second run.
security delete-keychain "$KEYCHAIN_PATH" 2>/dev/null || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$STAGE_DIR/devid.p12" -k "$KEYCHAIN_PATH" -P "$P12_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security

# codesign's chain-building for a --keychain-scoped identity only looks inside
# that keychain (plus System Roots) — it does NOT fall back to the rest of the
# search list. Machines that haven't previously done a Developer ID signing
# operation are missing this specific intermediate (there are multiple
# same-named "Developer ID Certification Authority" certs in Apple's PKI; the
# AIA URL below is read directly off our leaf cert, so it's always the right
# one), and codesign fails with "unable to build chain to self-signed root" /
# errSecInternalComponent without it.
curl -fsSL http://certs.apple.com/devidg2.der -o "$STAGE_DIR/devidg2.der"
security import "$STAGE_DIR/devidg2.der" -k "$KEYCHAIN_PATH"

# codesign needs to use the key without a per-item prompt (headless build).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

# Add to the search list (without wiping whatever's already there) so
# codesign can actually find the identity by name.
EXISTING_KEYCHAINS="$(security list-keychains -d user | tr -d '"')"
# shellcheck disable=SC2086
security list-keychains -d user -s $EXISTING_KEYCHAINS "$KEYCHAIN_PATH"

IDENTITY_NAME="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
if [ -z "$IDENTITY_NAME" ]; then
  echo "error: no Developer ID Application identity found after import — check the p12/password in Infisical." >&2
  exit 1
fi

# --- App Store Connect API key (also valid for notarytool auth) ------------
infisical_get ASC_KEY_P8 | base64 -d > "$STAGE_DIR/asc_key.p8"
ASC_KEY_ID="$(infisical_get ASC_KEY_ID)"
ASC_ISSUER_ID="$(infisical_get ASC_ISSUER_ID)"

export MAC_DEVID_APP_IDENTITY="$IDENTITY_NAME"
export MAC_DEVID_KEYCHAIN="$KEYCHAIN_PATH"
export ASC_KEY_PATH="$STAGE_DIR/asc_key.p8"
export ASC_KEY_ID="$ASC_KEY_ID"
export ASC_ISSUER_ID="$ASC_ISSUER_ID"

echo "Staged: $MAC_DEVID_APP_IDENTITY"
echo "Keychain: $MAC_DEVID_KEYCHAIN"
echo "Notary key: $ASC_KEY_PATH (key id $ASC_KEY_ID)"
echo "Ready — run: bundle exec fastlane build_notarized"
