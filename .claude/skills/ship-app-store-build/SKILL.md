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

Note: the MAS build cannot launch outside the App Store/TestFlight — its
"Mac App Store" provisioning profile is rejected at spawn (launchd error
163; verified 2026-08-26). The install-to-/Applications step therefore
lives on `build_notarized` (see the `release-notarized` skill), whose
Developer ID + stapled output launches directly. To run the MAS build
itself, install it via TestFlight.

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

## Doing the "manual" App Store Connect steps from the CLI

Everything the sections above hand off to the web UI — attaching a build,
screenshots, metadata, age rating, readiness — is scriptable with the `asc`
CLI (`/opt/homebrew/bin/asc`). Verified end-to-end 2026-08-31.

### Auth: use a repo-local config, not the keychain

```bash
python3 -c "import json,os;d=json.load(open('secrets/api_key.json'));\
fd=os.open('/tmp/AuthKey.p8',os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600);\
os.fdopen(fd,'w').write(d['key'])"
asc auth login --bypass-keychain --local --name gloam-studio \
  --key-id "$(python3 -c "import json;print(json.load(open('secrets/api_key.json'))['key_id'])")" \
  --issuer-id "$(python3 -c "import json;print(json.load(open('secrets/api_key.json'))['issuer_id'])")" \
  --private-key /tmp/AuthKey.p8 --network
```

**Use `--bypass-keychain --local`.** The default keychain path stores the key
happily and then fails to read it back non-interactively — every later command
dies with `credentials not found for profile "<name>"`. `--local` writes
`./.asc/config.json`, which **must be gitignored** (it carries key material).

### Find the IDs everything else needs

```bash
asc apps list --output table                       # app id
asc status --app APP_ID                            # version id, build state, blockers
asc localizations list --version VERSION_ID        # version-localization id (per locale)
asc localizations list --app APP_ID --type app-info  # app-info id (name/subtitle live here)
```

### `asc validate` is the source of truth

```bash
asc validate --app APP_ID --version-id VERSION_ID --output markdown
```

Run it before and after every change. It returns an ordered remediation plan;
work the list top-down until `Errors 0 / Blocking 0`. Trust it over the web UI
and over this document.

### A rejected submission freezes the version

If `validate` says `version is in non-editable state "READY_FOR_REVIEW"`, an
old submission is still open — a rejection sitting in `UNRESOLVED_ISSUES`
counts. **You cannot attach a build or edit any metadata until it is
cancelled.** This silently blocked a resubmission for weeks:

```bash
asc review submissions list --app APP_ID     # find the one that isn't COMPLETE
asc submit cancel --id SUBMISSION_ID --app APP_ID --confirm
```

The version then drops to `DEVELOPER_REJECTED`, which is editable, and moves to
`PREPARE_FOR_SUBMISSION` once a build is attached. A submission may also sit in
`READY_FOR_REVIEW` and refuse to cancel ("not in cancellable state"); that one
is harmless once the real blocker is gone.

### Attach the build, replace the screenshots

```bash
asc versions attach-build --version-id VERSION_ID --build-id BUILD_ID

asc screenshots upload --version-localization VERSION_LOCALIZATION_ID \
  --path store/screenshots/mac/en-US --device-type APP_DESKTOP --replace --dry-run
# then swap --dry-run for --confirm
```

`--replace` deletes every existing screenshot in the set first, so **always
dry-run it** and read the `would-delete` / `would-upload` list.

macOS display type is `APP_DESKTOP`; screenshots are 2880x1800. Keep them
in-repo (`store/screenshots/mac/<locale>/`) — they are release artifacts, and
capturing them into a temp dir means losing them.

### Metadata that review actually rejects on

```bash
asc localizations update --id VERSION_LOCALIZATION_ID \
  --support-url "https://example.com/support"
asc localizations update --type app-info --id APP_INFO_LOCALIZATION_ID \
  --subtitle "Under 30 chars"
```

**Deploying a support page does not update the support URL in ASC.** These are
two unrelated changes, and forgetting the second leaves a Guideline 1.5
rejection live in the metadata while the page sits there looking fixed. After a
support-URL rejection, always re-read the stored value:

```bash
asc localizations list --version VERSION_ID --locale en-US --output json | grep supportUrl
```

Also check what it resolves to — a URL that 301/308-redirects is worth
replacing with the final one.

### Age rating: the newer fields block submission

`socialMedia` and `socialMediaAgeRestricted` are recent additions and are
*unset* on older app records, which `validate` reports as blocking errors:

```bash
asc age-rating view --app APP_ID
asc age-rating edit --app APP_ID --social-media false --social-media-age-restricted false
```

ASC only accepts `--social-media true` when `--user-generated-content true`,
and `--social-media-age-restricted true` when age assurance and social media
are both true.

### What still genuinely needs the web UI

- **App Privacy** publish state is not readable via the public API. `validate`
  flags this as an info, and it can still block submission:
  `https://appstoreconnect.apple.com/apps/APP_ID/appPrivacy`
- **Release type MANUAL** means an approved version does not go live on its
  own (`asc versions release --version-id VERSION_ID --confirm` releases it).

Do not try to drive the ASC web UI with a browser tool — it requires an Apple
ID password and 2FA, which an agent must not enter. Ask the human to log in.

## The app icon: ASC reads AppIcon.icns, and actool truncates it

**Symptom:** the logo in App Store Connect looks soft, small, or "wrong", while
the icon in the repo is fine and the app looks correct in Finder.

**Cause:** the store icon comes from `AppIcon.icns` in the app bundle — the
build's `iconAssetToken` literally points at `.../AppIcon.icns` — and *not*
from `Assets.car`. Modern `actool` writes only a small compatibility icns:
`ic04`/`ic11`/`ic07`/`ic13` = 16, 32, 128, 256. **No 512, no 1024.** So ASC
receives a 256px image and upscales it everywhere.

Two things that look like the cause and are not:

- *"The asset catalog is missing sizes."* It isn't. `assetutil --info
  Assets.car` shows all ten renditions including `icon-1024.png` at scale 2.
- *"Reusing one PNG across two slots makes actool drop the duplicates."* It
  doesn't. A from-scratch `actool` run over ten distinct per-slot files emits
  the same four elements. This is actool behaving as designed.

**Fix**, wired into `project.yml` as a `postBuildScripts` phase:
`scripts/embed-full-appicon.sh` rebuilds the icns with `iconutil` (which
honours every size) after the resource phase and before signing, so the
signature covers what it writes. `scripts/verify-appicon-icns.py` then asserts
`ic09` (512) and `ic10` (1024) are present and **fails the build** if not — a
soft logo is otherwise invisible until someone looks at the listing.

Two gotchas if you touch that phase:

- `ENABLE_USER_SCRIPT_SANDBOXING: YES` means **every file the script reads must
  be listed in `inputFiles`**, and it may only write its declared `outputFiles`.
  Three separate denials came out of this, all of which pass a plain `build`
  and only fail at `archive` time:
  - Staging the iconset under `DERIVED_FILE_DIR` is denied
    (`mkdir deny(1) file-write-create`) -- build it in `mktemp -d`.
  - `iconutil` unlinks its output before writing, and the sandbox permits
    writing a declared output but **not unlinking it**
    (`deny(1) file-write-unlink`) -- write to a temp path and truncate the
    destination with `cat >`.
  - `BUILT_PRODUCTS_DIR` and `TARGET_BUILD_DIR` **diverge during an
    archive/install build**; using the former writes into
    `InstallationBuildProductsLocation` while the grant went elsewhere
    (`deny(1) file-write-data`). Use `TARGET_BUILD_DIR` in both the script and
    `outputFiles`.

  Always verify a build-phase change with `fastlane build_pkg`, not just
  `xcodebuild build` -- the archive sandbox is stricter.
- A correct icns is ~770KB. If it's ~60KB, actool's version is still winning.

Check any built app with:

```bash
./scripts/verify-appicon-icns.py path/to/App.app/Contents/Resources/AppIcon.icns
```

And check what ASC actually holds for an uploaded build — ask for 1024 and see
what comes back:

```bash
asc builds info --app APP_ID --latest --output json | python3 -c \
 "import json,sys;print(json.load(sys.stdin)['data']['attributes']['iconAssetToken'])"
```

If that reports `"width": 256`, the uploaded build has the truncated icns and
**no metadata change will fix it** — it needs a new build.
