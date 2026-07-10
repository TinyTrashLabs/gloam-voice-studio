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

Run from the repo root, with Tailscale up (`infisical.tinytrashlabs.com`
only resolves on the tailnet):

```bash
cd /path/to/gloam-voice-studio   # repo root, not a worktree
SHIP="$(find ~/.claude/plugins/marketplaces -path '*/skills/ship-beta/scripts/ship.sh' | head -1)"
"$SHIP" macos
```

`ship.sh macos` does everything: `xcodegen generate`, stages signing from
Infisical (reads `macos.infisical.*` from `app-build.config.json`), then runs
`fastlane mac beta` = preflight + `build_pkg` (archive → manual codesign with
the project's real entitlements → productbuild `.pkg`) + `upload` (`xcrun
altool --upload-app`). Takes several minutes, mostly the archive step.

As of the 2026-07-09 fix to `infisical-macos-signing.sh` (two real bugs —
`ASC_KEY_PATH` pointing at a file its own cleanup trap deleted before
`fastlane` read it, and `MAC_PROFILE_PATH` never being exported despite
`build_pkg` requiring it) this runs straight through with no manual
workarounds. If you hit either failure again, the plugin fix may not have
propagated — check
`~/.claude/plugins/marketplaces/tinytrashlabs/scripts/infisical-macos-signing.sh`
for a `WORK="$(mktemp -d)"` line *without* `; trap 'rm -rf "$WORK"' EXIT`
right after it, and an `export MAC_PROFILE_PATH=...` line near the bottom —
if either is missing, the plugin regressed or you're on a stale checkout.

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
