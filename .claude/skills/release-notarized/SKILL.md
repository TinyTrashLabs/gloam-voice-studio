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
2. Imports the identity into a dedicated, throwaway keychain
   (`~/Library/Keychains/gloam-devid-build.keychain-db`) — never touches your
   login keychain.
3. `fastlane build_notarized` archives Release config, codesigns with hardened
   runtime, submits to `notarytool --wait`, staples the ticket, and zips the
   result to `build/macos/GloamVoiceStudio-<version>-macOS.zip`.

Takes ~5–8 minutes, mostly the archive step and the notarization wait.

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

## Gotcha 3 — re-running `stage-devid-signing.sh` must start from a fresh keychain

The script generates a new random keychain password every run. If a leftover
keychain file from a prior run survives, the new random password won't match
it, and `security import`'s ACL/trust update silently fails (you'll see
`SecKeychainItemSetAccessWithPassword: ... not correct` but the script won't
abort). The script deletes and recreates the keychain unconditionally each
run specifically to avoid this — don't "optimize" that into a conditional
create.

## If you need the App Store build instead

That's `fastlane build_pkg` — signing material for it is staged by the
external `ship.sh`/`infisical-macos-signing.sh` tooling (not in this repo),
using the `MAC_APP_CERT_P12`/`MAC_INSTALLER_CERT_P12` secrets at the same
Infisical path. `build_pkg` and `build_notarized` are independent lanes; you
don't need one staged to run the other.
