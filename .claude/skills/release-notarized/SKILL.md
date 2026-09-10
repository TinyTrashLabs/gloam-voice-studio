---
name: release-notarized
description: Build a Developer ID-signed, notarized, Gatekeeper-accepted GloamVoiceStudio.app for direct distribution (GitHub releases) — outside the Mac App Store. Use when asked to cut a public/GitHub release build, notarize the app, or stage Developer ID signing material.
---

# Developer ID notarized build (direct distribution)

This is the **GitHub-release** path, separate from the Mac App Store path
(`fastlane build_pkg`, staged by the external ship.sh tooling). Public builds
posted outside the App Store must be signed with a **Developer ID Application**
certificate and **notarized**, or Gatekeeper blocks them on a fresh Mac.

## One-time: get Infisical access

Signing material lives in the company's self-hosted Infisical, at the path
this repo's own `app-build.config.json` points to
(`/gloam-voice-studio-macos-signing`, project `d5b50b4d-a82b-4cc7-b52c-7b375b31f7ac`,
env `prod`, domain `https://infisical.tinytrashlabs.com`) — **not**
`app.infisical.com`. Ask a teammate who already has access to add you, then:

```bash
infisical login --domain https://infisical.tinytrashlabs.com
```

## Recipe (verified end-to-end)

Run from the repo root. `source` (not execute) the staging script so its
exported env vars reach `fastlane` in the same shell:

```bash
source scripts/stage-devid-signing.sh
fastlane build_notarized
```

This:
1. Pulls the Developer ID Application `.p12` + password and the App Store
   Connect API key (also valid for notarytool auth) from Infisical.
2. Unlocks the **persistent** `~/Library/Keychains/gloam-devsign.keychain-db`
   with the tooling-owned password (`~/.config/gloam/devsign-keychain-pass`,
   source of truth `MAC_DEVSIGN_KEYCHAIN_PASSWORD` in Infisical
   `/gloam-macos-signing`), imports the Developer ID identity into it only if
   missing, and verifies it is in the user keychain search list. It never
   touches your login keychain and never creates a throwaway keychain — the
   old per-run `gloam-devid-build.keychain-db` (random password, 1 h auto-lock)
   is what kept producing keychain dialogs on screen (2026-09-10 and before).

**Before running either command: this signs, and a wrong keychain state turns
into a GUI keychain prompt on David's screen. Ask first, every time. If it
fails, do not re-run it blind — see CLAUDE.md "Signing and notarizing".**
3. `fastlane build_notarized` archives Release config, codesigns with hardened
   runtime, submits to `notarytool --wait`, staples the ticket, and zips the
   result to `build/macos/GloamVoiceStudio-<version>-macOS.zip`.

Takes ~5–8 minutes, mostly the archive step and the notarization wait.

`build_notarized` also installs the stapled .app into `/Applications`,
replacing any existing copy — Developer ID + stapled ticket launches
directly, unlike the MAS build from `build_pkg` (whose App Store profile
is rejected locally with launchd error 163). Quit and relaunch the app
after a build to pick it up. This step lives only in this machine's
gitignored Fastfile — mirror it into the marketplace template when
porting.

## Verify the output is actually Gatekeeper-clean

Don't trust "no error" — confirm Apple's own gatekeeper accepts it:

```bash
ditto -x -k build/macos/GloamVoiceStudio-*-macOS.zip /tmp/gvs-check
spctl --assess --type execute -vvv /tmp/gvs-check/GloamVoiceStudio.app
# expect: "accepted" / "source=Notarized Developer ID"
xcrun stapler validate /tmp/gvs-check/GloamVoiceStudio.app
# expect: "The validate action worked!"
```

## Gotcha 1 — the `.p12` must use legacy (RC2/3DES) encryption

`openssl pkcs12 -export` on modern OpenSSL (3.x) defaults to
PBES2/PBKDF2/AES-256-CBC. macOS's `security import` — Apple's own Security
framework PKCS12 parser, still true as of macOS 26 — cannot read that and
fails with `MAC verification failed during PKCS12 import (wrong password?)`,
which looks exactly like a wrong password but isn't. If you ever need to
regenerate this `.p12` (new cert, rotated key), export it with `-legacy`:

```bash
openssl pkcs12 -export -legacy -in cert.pem -inkey key.pem -out out.p12 -passout file:pwfile
```

The `.p12` stored in Infisical (`MAC_DEVELOPER_ID_APPLICATION_CERT_P12`,
base64-encoded) and in `secrets/devid/DeveloperIDApplication.p12` (gitignored
local copy) is already the legacy-encoded version — this only matters if
you're rotating the cert.

## Gotcha 2 — a missing intermediate breaks codesign, not import

`security import` can succeed while `codesign` still fails with
`unable to build chain to self-signed root` / `errSecInternalComponent`.
Apple has multiple same-named "Developer ID Certification Authority"
intermediates across parallel PKI hierarchies (an old one many Macs already
have cached, and the current "G2" one this cert actually chains to) —
`codesign`'s chain-building for a keychain-scoped identity only looks inside
that keychain (+ System Roots), so a machine that's never done a Developer ID
signing operation before is very likely missing the right one. `find-identity`
reporting `0 valid identities found` right after a successful import is the
tell. `stage-devid-signing.sh` fetches the exact needed intermediate straight
off the leaf cert's own AIA extension (`http://certs.apple.com/devidg2.der`)
and imports it — this is already handled, but is why the script needs network
access to `certs.apple.com` even before notarization's own network calls.

## Gotcha 3 — the keychain is persistent; never delete or recreate it

`stage-devid-signing.sh` used to generate a random keychain password and
delete/recreate its keychain every run. That design is retired: the keychain
is now the shared `gloam-devsign.keychain-db` with a known password, no
auto-lock, and the identity is imported once. If unlock fails, the password
was rotated — refresh `~/.config/gloam/devsign-keychain-pass` from Infisical.
If the keychain file is gone, rebuild it per
`docs/superpowers/2026-07-08-macos-dev-cert-signing-recovery.md`. Do not
reintroduce a throwaway keychain.

## Gotcha 4 — codesign ignores `--keychain` for a keychain outside the search list

If the keychain is not in `security list-keychains -d user`, codesign reports
`no identity found`, or worse resolves the same-named Developer ID cert in
`login.keychain` and prompts for its password (→ `errSecInternalComponent`).
The staging script now verifies membership and fails loudly. Check this first
whenever a signing step misbehaves.

## If you need the App Store build instead

That's `fastlane build_pkg` — signing material for it is staged by the
external `ship.sh`/`infisical-macos-signing.sh` tooling (not in this repo),
using the `MAC_APP_CERT_P12`/`MAC_INSTALLER_CERT_P12` secrets at the same
Infisical path. `build_pkg` and `build_notarized` are independent lanes; you
don't need one staged to run the other.
