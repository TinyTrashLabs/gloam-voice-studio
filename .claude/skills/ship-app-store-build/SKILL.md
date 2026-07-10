---
name: ship-app-store-build
description: Build and upload a new Mac App Store build (.pkg) of GloamVoiceStudio to App Store Connect via the shared ios-android-builder plugin's ship.sh. Use when asked to ship/upload/submit a new build, bump the build number for a resubmission, or fix "Missing Compliance"/build-attach issues in App Store Connect.
---

# Shipping a Mac App Store build

This is the **App Store** path (`fastlane build_pkg` + upload), separate from
the Developer ID direct-distribution path — see the `release-notarized` skill
for that one. Signing material comes from the same Infisical project, staged
by the `ios-android-builder` plugin's `ship.sh`/`infisical-macos-signing.sh`
(not part of this repo).

## 0. Bump the build number

`project.yml`'s `CURRENT_PROJECT_VERSION` is the single source of truth (feeds
`Info.plist` via `$(CURRENT_PROJECT_VERSION)`). Bump it, commit on a
`chore/build-N` branch, PR, merge — `main` is rule-protected, no direct pushes.
App Store Connect rejects an upload whose build number isn't higher than the
last one it saw.

## Recipe (verified end-to-end 2026-07-09)

`ship.sh` normally does staging + `fastlane mac beta` in one shot, but two
bugs in its signing script (below) mean the direct call fails partway
through. Do it in three steps instead so you can apply the workarounds
in between:

```bash
cd /path/to/gloam-voice-studio   # repo root, not a worktree

# 1. Stage signing from Infisical (reads macos.infisical.* from app-build.config.json)
SCRIPT="$(find ~/.claude/plugins -path '*/scripts/infisical-macos-signing.sh' | head -1)"
source secrets/env.sh   # INFISICAL_CLIENT_SECRET
export INFISICAL_HOST="https://infisical.tinytrashlabs.com"
export INFISICAL_PROJECT_ID="d5b50b4d-a82b-4cc7-b52c-7b375b31f7ac"
export INFISICAL_CLIENT_ID="ba1f89ac-5083-45cd-98b4-386b02e5b00b"
export INFISICAL_ENV="prod"
eval "$(INFISICAL_MACOS_PATH=/gloam-voice-studio-macos-signing "$SCRIPT" "$PWD" fm.gloam.studio UT233385J9 "$PWD/secrets/api_key.json")"

# 2. Apply the two workarounds (see Gotchas below)
unset ASC_KEY_PATH
DEST="$HOME/Library/MobileDevice/Provisioning Profiles"
NEWEST="$(ls -t "$DEST"/*.provisionprofile | head -1)"
export MAC_PROFILE_PATH="$NEWEST"

# 3. Build, sign, and upload
fastlane mac beta
```

`fastlane mac beta` = preflight + `build_pkg` (archive → manual codesign with
the project's real entitlements → productbuild `.pkg`) + `upload` (`xcrun
altool --upload-app`). Takes several minutes, mostly the archive step.

## Gotcha 1 — `ASC_KEY_PATH` points at a file that's already deleted

`infisical-macos-signing.sh` writes the ASC API key to a `mktemp -d` scratch
dir with `trap 'rm -rf "$WORK"' EXIT`, then **also** prints
`export ASC_KEY_PATH="$P8"` pointing into that same dir. Since the script
runs to completion (via `eval "$(...)"` command substitution) before its
output is ever eval'd by the caller, the trap fires and deletes the file
*before* `fastlane` reads it — `IO.read: No such file or directory
@ rb_sysopen - .../tmp.XXXXXX/AuthKey.p8`. The same key material is *also*
written to the persistent `secrets/api_key.json` (the script's 4th arg), and
the Fastfile's `asc_key_material` already falls back to that file when
`ASC_KEY_PATH` is unset — so the fix is just `unset ASC_KEY_PATH` after
staging, not touching the plugin script.

## Gotcha 2 — `MAC_PROFILE_PATH` is never exported at all

`fastlane build_pkg`'s `UI.user_error!("MAC_PROFILE_PATH not set...")` check
fires unconditionally when called after plain staging — the staging script's
final `export ...` block simply doesn't include it (only `MAC_PROFILE_NAME`,
the human-readable name). The script *does* install the actual profile file
to `~/Library/MobileDevice/Provisioning Profiles/<uuid>.provisionprofile`
first, though — so find the just-installed one (newest mtime) and export its
path yourself. `security cms -D -i <path> | plutil -extract Name raw -` (or
`/usr/libexec/PlistBuddy -c 'Print :Name'` on the decoded plist) confirms it's
named "Gloam Voice Studio Mac App Store" if you want to double check before
trusting "newest".

Neither bug has been reported upstream to the `ios-android-builder` plugin
yet — worth fixing there so other projects using the same plugin don't hit
this too.

## After upload: export compliance

A freshly uploaded build always shows **Missing Compliance** in App Store
Connect until you answer the encryption questionnaire, and a build can't be
attached to the app version while it's missing. In the app version page →
Build → **Add Build** → select the new build → **Manage** → App Encryption
Documentation → **None of the algorithms mentioned above** (this app only
uses standard HTTPS/OS-provided TLS, no custom encryption) → Save. Then
**Save** the app version page itself before **Update Review** /
**Add for Review**.

## If you need the notarized (direct-distribution) build instead

That's `fastlane build_notarized` — see the `release-notarized` skill. It's
an independent lane from `build_pkg`/`beta`; you don't need one staged to run
the other, though both pull from the same Infisical project.
