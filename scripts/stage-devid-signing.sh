#!/usr/bin/env bash
# Stages Developer ID signing + notarization material from Infisical into the
# persistent gloam-devsign keychain and a set of env vars, for `fastlane build_notarized`.
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

# --- The keychain: the PERSISTENT gloam-devsign one, never a throwaway ------
#
# This used to create a fresh `gloam-devid-build.keychain-db` with a random
# password and a 1-hour auto-lock on every run. That is the exact recipe for
# keychain-access dialogs on David's screen: the throwaway keychain drops out
# of the search list / locks, codesign then resolves the identity by NAME in
# login.keychain (which also holds a Developer ID cert) and asks for a login
# keychain password nobody knows. Documented since 2026-07-09 in the aidj
# memory (macos-devsign-keychain-recovery) and docs/superpowers/2026-07-08-
# macos-dev-cert-signing-recovery.md: use ONE persistent keychain whose
# password the tooling owns — cached at ~/.config/gloam/devsign-keychain-pass,
# source of truth MAC_DEVSIGN_KEYCHAIN_PASSWORD in Infisical
# /gloam-macos-signing — with no auto-lock, unlocked non-interactively at the
# top of every run, and a hard failure instead of a GUI prompt.
KEYCHAIN_PATH="${MAC_DEVID_KEYCHAIN:-$HOME/Library/Keychains/gloam-devsign.keychain-db}"
KC_PASS_FILE="$HOME/.config/gloam/devsign-keychain-pass"
KEYCHAIN_PASSWORD=""
[ -f "$KC_PASS_FILE" ] && KEYCHAIN_PASSWORD="$(cat "$KC_PASS_FILE")"
if [ -z "$KEYCHAIN_PASSWORD" ]; then
  KEYCHAIN_PASSWORD="$(infisical secrets get MAC_DEVSIGN_KEYCHAIN_PASSWORD \
    --path /gloam-macos-signing --projectId "$INFISICAL_PROJECT_ID" \
    --env "$INFISICAL_ENV" --domain "$INFISICAL_DOMAIN" --include-imports=false --plain 2>/dev/null || true)"
  if [ -n "$KEYCHAIN_PASSWORD" ]; then
    mkdir -p "$HOME/.config/gloam"
    printf '%s' "$KEYCHAIN_PASSWORD" > "$KC_PASS_FILE"
    chmod 600 "$KC_PASS_FILE"
  fi
fi
if [ -z "$KEYCHAIN_PASSWORD" ]; then
  echo "error: no password for $KEYCHAIN_PATH (no $KC_PASS_FILE, Infisical unreachable)." >&2
  echo "       Building now would GUI-prompt for a keychain password. Get on the tailnet and re-run." >&2
  exit 1
fi
if [ ! -f "$KEYCHAIN_PATH" ]; then
  echo "error: $KEYCHAIN_PATH does not exist. Rebuild it from the Infisical p12 backup:" >&2
  echo "       docs/superpowers/2026-07-08-macos-dev-cert-signing-recovery.md → recovery recipe." >&2
  exit 1
fi
if ! security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" 2>/dev/null; then
  echo "error: unlock of $KEYCHAIN_PATH failed (password rotated?). Refresh $KC_PASS_FILE from Infisical" >&2
  echo "       (MAC_DEVSIGN_KEYCHAIN_PASSWORD at /gloam-macos-signing) — do NOT recreate the keychain." >&2
  exit 1
fi
# No auto-lock, no lock-on-sleep: a locked keychain in the search list is what
# turns every later codesign into a dialog.
security set-keychain-settings "$KEYCHAIN_PATH"

# --- Developer ID Application identity (base64 p12 + password) -------------
# Import only when the keychain doesn't already hold it; re-importing the same
# identity is harmless but noisy, and the point of a persistent keychain is
# that this is normally a no-op.
if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep -q "Developer ID Application"; then
  echo "Importing the Developer ID Application identity into $KEYCHAIN_PATH..."
  infisical_get MAC_DEVELOPER_ID_APPLICATION_CERT_P12 | base64 -d > "$STAGE_DIR/devid.p12"
  P12_PASSWORD="$(infisical_get MAC_DEVELOPER_ID_APPLICATION_CERT_PASSWORD)"
  security import "$STAGE_DIR/devid.p12" -k "$KEYCHAIN_PATH" -P "$P12_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security
fi

# codesign's chain-building for a --keychain-scoped identity only looks inside
# that keychain (plus System Roots) — it does NOT fall back to the rest of the
# search list. Machines that haven't previously done a Developer ID signing
# operation are missing this specific intermediate (there are multiple
# same-named "Developer ID Certification Authority" certs in Apple's PKI; the
# AIA URL below is read directly off our leaf cert, so it's always the right
# one), and codesign fails with "unable to build chain to self-signed root" /
# errSecInternalComponent without it. Importing an already-present cert is a
# no-op.
curl -fsSL http://certs.apple.com/devidg2.der -o "$STAGE_DIR/devidg2.der"
security import "$STAGE_DIR/devidg2.der" -k "$KEYCHAIN_PATH" 2>/dev/null || true

# codesign needs to use the key without a per-item prompt (headless build).
# This is the step that, when it silently fails, becomes a dialog on screen —
# so it is NOT silenced.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

# Make sure the keychain is in the search list (idempotent, keeps the others),
# then VERIFY: codesign will not use an identity from a keychain outside the
# list even when handed --keychain, and it may then find a same-named cert in
# login.keychain and prompt.
EXISTING_KEYCHAINS="$(security list-keychains -d user | tr -d '"' | grep -v "$(basename "$KEYCHAIN_PATH")" || true)"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING_KEYCHAINS
security list-keychains -d user | grep -q "$(basename "$KEYCHAIN_PATH")" \
  || { echo "error: $KEYCHAIN_PATH is not in the user keychain search list after list-keychains -s." >&2; exit 1; }

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
