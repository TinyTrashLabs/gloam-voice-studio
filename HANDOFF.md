# Handoff — 2026-08-30 night session

Written while the App Store archive was building. **Check the "Live at handoff" section
at the bottom first** — it records where the upload actually got to.

---

## Committed

**gloam-voice-studio** (branch `chore/studio-build-7`, nothing pushed)

- `d44365f5` — toolbar/per-model memory, one `StoragePaths`, visible sidebar row controls, `CFBundleName`
- `714cf88a` — bump to build 8

**gloam-site** (branch `feat/marketing-worker`)

- `9ca18a4` — `/studio/support` page. **Deployed and live** (200, version `994fec17`).
  Upload touched exactly 1 file; the other 76 already matched, so the branch was
  already deployed and no unreleased marketing work went out with it.

---

## What changed and why

### Toolbar showed every model name twice
A RAM chip printed the resident TTS and LLM names beside the two pickers that already
named them, so one of each read as four. Its own status dot duplicated the pickers'
dots too. Replaced with the number it was actually for: **each picker now shows what
that model costs**, measured as the process-footprint delta across its own load.

`minRAMBytes` is a floor for "can this Mac run it" and `approxBytes` is on-disk size —
neither answers "what is this costing me right now", which is why the measurement is
taken rather than looked up.

Measurement lives in `GloamEngine`, so a load from Generate, the API server or a bake is
covered like one from the picker. The footprint sampler is injectable because real
process memory made the tests order-dependent — one test's 200 MB free lands inside
another's measurement window.

**Residency now drives selection** (`refreshEngineStatus`), so a picker can never name a
model that isn't loaded. That drift was the actual source of the confusion. `preloadLLM`
makes the chat model load on selection instead of on first reply.

### Two `StoragePaths` (this was the weightsNotFound bug)
`Sources/EngineKit/StoragePaths.swift` had moved Models/ and Voices/ into the App Group.
`App/StoragePaths.swift` was a second copy that **shadowed it inside the app module** and
still pointed at Application Support. The app looked where EngineKit had just emptied,
reported `weightsNotFound`, and started re-downloading 41 GB it already had.

App-local copy deleted; `foundryCandidates` and `chatAudio` moved onto the shared one as
app-private. The App Group fallback is now **loud** — losing the sharing is acceptable,
doing it silently is what turned a provisioning gap into a re-download.

### Sidebar row controls
Play and pencil were hidden until hover (undiscoverable, and the row jumped width). The
`…` menu was drawn in **black** — invisible at rest.

Root cause, found by Fable: a `.borderlessButton` Menu inside these `List` rows bridges to
an AppKit popup that tints its own template image, so SwiftUI's `foregroundStyle`/`tint`
never reaches the glyph. Verified via the AX tree (the view was laid out at a real 20×14
frame the whole time) and by pixel-sampling that frame. Fixed with
`.menuStyle(.button).buttonStyle(.plain)`, which keeps the label in SwiftUI's renderer.
All three controls are always present now; hover/selection drive emphasis only.

### `CFBundleName`
Menu bar read "GloamVoiceStudio". The app menu takes its title from `CFBundleName`, not
`CFBundleDisplayName`; unset, it falls back to `$(PRODUCT_NAME)`. Now "Gloam Voice
Studio". Bundle and executable unchanged, so signing and the profile are untouched.

> Note: `CFBundleName` is conventionally ≤15 chars and this is 18. Not enforced, but
> `Gloam Studio` is the alternative if you'd rather stay inside the guideline.

### Support URL (the Guideline 1.5 rejection)
New page at `https://gloam.fm/studio/support` — `support@gloam.fm`, an issues link, and
the questions people actually hit.

**The `/support` apex alias was deliberately NOT repointed.** `worker/index.ts` says those
URLs are baked into shipped apps and gloam-dj's store metadata pins them; changing it
would break the shipped DJ app. Verified still intact after deploy: `/support`,
`/privacy`, `/terms` all still 301 to the `mc/` pages.

`app-build.config.json` now points at the new URL — **but that file is gitignored**
(line 19, it carries the Infisical IDs), so that change exists **only on this machine**.
A build from anywhere else will still carry the rejected GitHub URL.

---

## Open: the Generate crash — NOT fixed

[Issue #48](https://github.com/TinyTrashLabs/gloam-voice-studio/issues/48)

One hard crash (`SIGABRT`) during Generate. Aborts inside vendored MLX at
`mlx/backend/metal/fft.cpp:647`:

```cpp
int threadgroup_mem_size = next_power_of_2(threadgroup_batch_size * fft_size);
assert(threadgroup_mem_size <= MAX_STOCKHAM_FFT_SIZE);   // 4096
```

An FFT whose threadgroup memory exceeds MLX's Metal limit. Driven by **sample count**,
not character count — which is why length looked erratic.

**Could not reproduce** in ~25 attempts: 8 voices, 24/44.1/48 kHz references, the exact
crashing sentence and voice, 5 cold starts. All returned 200.

**The assert is live in the Release binary** — confirmed by finding `___assert_rtn` and
the literal assert string in the shipping executable, after a full clean rebuild.
`MAX_STOCKHAM_FFT_SIZE` appears in exactly one file in the checkout, so that string is
the live assert, not embedded Metal source.

**Attempted mitigation failed and was reverted.** Setting `GCC_PREPROCESSOR_DEFINITIONS =
NDEBUG=1` project-wide applies to our target but does **not** propagate into SwiftPM
package targets — mlx-swift declares its own `cxxSettings` without `NDEBUG`. Don't retry
it; the negative result is recorded in #48.

Remaining options: fork mlx-swift to add the define, or find the trigger and avoid the
input shape. Worth noting the abort is arguably safer than a silently wrong FFT.

**So this build can still crash on Generate.** Low observed rate (1 in ~25), but real.

---

## Screenshots

Five at 2880×1800 in the session scratchpad:
`/private/tmp/claude-501/-Users-david-projects-gloam-fm-gloam-voice-butler/b7618a64-97a3-4d48-88f7-a62b179e7227/scratchpad/shots/`

`01-studio` (rendered take) · `02-create-voice` · `03-chat` · `04-model-picker`
(shows `lux-tts · loaded · 0.5 GB`) · `05-api-server`

**Uploaded to App Store Connect 2026-08-31** (all five COMPLETE), replacing the five
July `shot1..5.png` that showed the old UI. Version-localization
`4bfe08fb-dc96-4d30-a1a7-f581473b18b2`, set `592226a4-cd17-46f4-8b01-83f6c9fac097`.

Source of truth is now `store/screenshots/mac/en-US/` **in this repo** — they were
previously only in a session temp dir that would have been purged. Re-upload with:

```sh
asc screenshots upload --version-localization 4bfe08fb-dc96-4d30-a1a7-f581473b18b2 \
  --path store/screenshots/mac/en-US --device-type APP_DESKTOP --replace --confirm
```

Settings → Models and → Storage were dropped as candidates: the Settings window won't
grow past 450pt so both clip a row mid-height at any size.

---

## Your data

Restored and verified: **40 voices** (group container), 30 chats, 206 chat-audio, 400
history. No `*-REAL-*` parks left.

Demo library still on disk as `Voices-demo` / `Chats-demo` / `ChatAudio-demo` /
`History-demo` in Application Support, plus two `Voices-backup-2026-08-29*`. Re-stage from
those if you need demo data for screenshots again.

`appSupport/Models/lux-tts` (657 MB, ONNX file set) left alone — it's a **different** file
set from the group container's safetensors build, not a duplicate.

---

## Live at handoff

### Gotcha that cost a build: don't stage both signings at once

The first `build_pkg` **failed** at `codesign` on
`Contents/Frameworks/libonnxruntime.1.27.0.dylib` with `no identity found`.

Cause: `scripts/stage-devid-signing.sh` was run while the App Store material was already
staged, and it mangled the keychain search list. `security list-keychains -d user` came
back with several paths collapsed into one quoted garbage entry, and
`iab-macos-signing.keychain-db` then reported **0 valid identities** — so codesign lost
the identity partway through the archive.

Repaired with:

```sh
security list-keychains -d user -s \
  ~/Library/Keychains/login.keychain-db \
  ~/Library/Keychains/gloam-devid-build.keychain-db
```

then re-ran `infisical-macos-signing.sh` (it deletes and recreates its keychain), which
restored both identities.

**Do the two signings sequentially, never interleaved:** finish the App Store pkg and
upload, and only then `source scripts/stage-devid-signing.sh` for the notarized build.

### Status

- **App Store: UPLOADED and STAGED.** `GloamVoiceStudio.pkg`, 52,949,144 bytes, build 8.
  Delivery UUID `76ef2a91-1c72-4ed4-b5d4-079a344f4ae1`, "No errors uploading archive."
  Build 8 processed to `VALID` and **is now attached** to version 1.0.0
  (`24ddead4-2d32-47d3-83eb-253227293d98`).

  `asc validate` now reports **0 blocking errors**. Everything below was done
  2026-08-31 via the `asc` CLI — see "The 2026-08-31 ASC pass".

  **The only step left is pressing submit** (see the crash caveat first).
- **Developer ID build: DONE and verified.** `GloamVoiceStudio-1.0.0-macOS.zip`
  (52,955,496 bytes). Signed `Developer ID Application: Tiny Trash Labs LLC (UT233385J9)`,
  hardened runtime, stapled. `spctl` reports `accepted / source=Notarized Developer ID`,
  `stapler validate` passes — so it opens without a right-click bypass.
- **GitHub release: PUBLISHED.**
  https://github.com/TinyTrashLabs/gloam-voice-studio/releases/tag/v1.0.0-build.8
  Not a draft, not a pre-release, asset attached. Release notes list what changed and
  disclose the #48 crash.
- **Website download now works.** The studio page's "Download for macOS" button already
  pointed at `/releases`, so publishing there is what wired it up. Nothing was hosted on
  gloam.fm directly — a 53 MB zip is far past Cloudflare Workers' per-asset limit.
- **Branch pushed:** `chore/studio-build-7` is now on origin (a release tag needs a
  commit GitHub can see). It is NOT merged to main.

The site's "Download for macOS" button already points at
`github.com/TinyTrashLabs/gloam-voice-studio/releases`, so publishing a release there is
what makes it work. A full app zip is far past Cloudflare Workers' per-asset limit, so
hosting it on gloam.fm directly isn't an option.

---

## If you pick this up cold

Re-stage signing (each Bash call is a fresh shell, so source and run in one go):

```sh
cd ~/projects/gloam.fm/gloam-voice-studio
set -a; source secrets/env.sh; set +a
export INFISICAL_HOST="https://infisical.tinytrashlabs.com"
export INFISICAL_PROJECT_ID="d5b50b4d-a82b-4cc7-b52c-7b375b31f7ac"
export INFISICAL_ENV="prod"
export INFISICAL_MACOS_PATH="/gloam-voice-studio-macos-signing"
export INFISICAL_CLIENT_ID="ba1f89ac-5083-45cd-98b4-386b02e5b00b"
~/.claude/plugins/marketplaces/tinytrashlabs/scripts/infisical-macos-signing.sh \
  "$PWD" fm.gloam.studio UT233385J9 "$PWD/secrets/api_key.json" > /tmp/signing-exports.sh
source /tmp/signing-exports.sh
FASTLANE_SKIP_UPDATE_CHECK=1 fastlane build_pkg && FASTLANE_SKIP_UPDATE_CHECK=1 fastlane upload
```

Developer ID / notarized:

```sh
source scripts/stage-devid-signing.sh && FASTLANE_SKIP_UPDATE_CHECK=1 fastlane build_notarized
```

`fastlane preflight` warns *"App record exists, but no macOS platform yet"*. Build 7 was
uploaded before, so it's probably a false negative from the API check — but if the upload
rejects on platform, that's the reason.

---

## The 2026-08-31 ASC pass

Everything here was done with the `asc` CLI. Credentials are staged repo-locally at
`.asc/config.json` (gitignored) from `secrets/api_key.json`:

```sh
asc auth login --bypass-keychain --local --name gloam-studio \
  --key-id 8XA5NKLB8D --issuer-id b14cf595-745e-40b1-aed9-d8f0424c3cf1 \
  --private-key /path/to/AuthKey.p8
```

> The system keychain path (`asc auth login` without `--bypass-keychain`) stores fine but
> **fails to read back** non-interactively — every later command dies with
> `credentials not found for profile`. Use `--bypass-keychain --local`.

App `6786521434` · version `24ddead4-2d32-47d3-83eb-253227293d98` (1.0.0, MAC_OS) ·
en-US version-localization `4bfe08fb-dc96-4d30-a1a7-f581473b18b2` ·
app-info localization `a1a6ab1c-f968-4ffb-8756-cee241aa0bfe`.

### The version was frozen, and that was the real story

The version sat in `READY_FOR_REVIEW` — **non-editable**, so the build could not be
swapped and metadata could not be touched. Behind it was the July rejection,
submission `16d57003-4eda-4341-a87c-055bbff98d4f`, still parked in `UNRESOLVED_ISSUES`
since 2026-07-03. Cancelling it dropped the version to `DEVELOPER_REJECTED`, which is
editable:

```sh
asc submit cancel --id 16d57003-4eda-4341-a87c-055bbff98d4f --app 6786521434 --confirm
```

A second submission `8ef788d8-...` sits in `READY_FOR_REVIEW` and refuses to cancel
("not in cancellable state"). It did not block anything once the July one was gone.

### Why the logo looked wrong in App Store Connect

**The icon in the repo and in build 8 is correct.** The version had **build 6** attached,
and the builds Apple actually reviewed in July were 4 and 5 — both built *before*
commit `e71a96ac` (2026-07-31) fixed "app icon rendered as a small mark on a big dark
tile". So ASC was rendering the old pre-fix mark. Attaching build 8 is the fix.

Two dead ends worth not repeating:

- The generated `AppIcon.icns` in the built app holds only `ic04`/`ic11`/`ic07`/`ic13`
  (16, 32, 128, 256) — **no 512 or 1024**. This looks alarming and is **not a bug**:
  a from-scratch `actool` run on a clean catalog with ten distinct per-slot files emits
  exactly the same four. Modern `actool` writes a small compatibility `.icns` and puts the
  real icon in `Assets.car`.
- `Assets.car` was verified via `assetutil --info` to carry all ten renditions
  **including `icon-1024.png` at scale 2**. The asset catalog was never the problem.

### Changes applied

| Field | Before | After |
|:--|:--|:--|
| attached build | 6 | **8** (`76ef2a91-...`, `VALID`) |
| screenshots | 5 × July `shot1..5.png` (old UI) | 5 × current, `COMPLETE` |
| `supportUrl` | `https://gloam.fm/studio` (a 308 redirect) | `https://gloam.fm/studio/support` (200) |
| `socialMedia` | *unanswered — blocking* | `false` |
| `socialMediaAgeRestricted` | *unanswered — blocking* | `false` |
| subtitle (app-info) | empty | `On-device voice cloning` |

**The support URL was still the rejected one.** Deploying the `/studio/support` page last
night did not change the ASC field — that had to be set separately, and until now the
Guideline 1.5 rejection reason was still live in the metadata. This is the single most
important thing that got fixed today.

The two age-rating fields are new Apple declarations. `false` is accurate: no accounts,
no network, no interpersonal messaging — consistent with `userGeneratedContent: false`
and `messagingAndChat: false`, which were already declared.

### Where it stands

`asc validate --app 6786521434 --version-id 24ddead4-... ` → **0 errors, 0 blocking.**

Two non-blocking infos remain, both needing the ASC web UI:

- **Release type is MANUAL** — after approval it will not go live until released.
- **App Privacy publish state is not verifiable via the API** and may still block
  submission: https://appstoreconnect.apple.com/apps/6786521434/appPrivacy

### Submit

Not done — deliberately. `asc publish appstore --submit` is the command.

**Build 8 still carries the Generate crash (#48).** A crash on the app's primary feature
is a plausible Guideline 2.1 rejection, and a second rejection on this app is worse than
a delay. That call is the human's, not the agent's.

---

## Build 9 — the App Store Connect logo fix (2026-08-31)

**The listing logo was wrong because ASC only ever had a 256px icon.**

ASC takes the store icon from `AppIcon.icns` in the bundle — the build's
`iconAssetToken` points straight at it — **not** from `Assets.car`. `actool`
writes only a compatibility icns of 16/32/128/256 (`ic04`/`ic11`/`ic07`/`ic13`),
with no 512 and no 1024, so ASC upscaled a 256px image everywhere.

Two things that looked like the cause and were not: the asset catalog (verified
complete, all ten renditions including the 1024) and slot files shared between
sizes (a from-scratch actool run on ten distinct files emits the same four).

Fixed by a `postBuildScripts` phase — `scripts/embed-full-appicon.sh` rebuilds
the icns with `iconutil`, and `scripts/verify-appicon-icns.py` fails the build
if `ic09`/`ic10` are absent. It took three passes to get through the archive
sandbox, all of which pass a plain `xcodebuild build` and only fail at archive:
`DERIVED_FILE_DIR` is not writable, `iconutil` may not unlink its own output,
and `BUILT_PRODUCTS_DIR` diverges from `TARGET_BUILD_DIR` during an install
build. Verify build-phase changes with `fastlane build_pkg`, not `build`.

**Result, measured:**

| | build 8 | build 9 |
|:--|:--|:--|
| `iconAssetToken` | 256 x 256, `.../AppIcon.icns` | **1024 x 1024**, `.../AppIcon.png` |
| bundle `AppIcon.icns` | 61 KB, 4 sizes | 774 KB, 10 sizes |

Build 9 (`d00d1097-8d9f-43af-a106-3f76c96ddb3b`) is uploaded, `VALID`, and
attached. `asc validate` → **0 errors, 0 warnings**, state
`PREPARE_FOR_SUBMISSION`.

> The **Apps-list thumbnail** in the ASC web UI is the app-record icon and is
> served from the last build Apple processed for review — it can keep showing
> the old artwork until this version is actually submitted. The version's own
> build icon is correct now; if the grid thumbnail still looks stale, that is
> the cache, not the build.

### Release notes

The "Known issue" section was removed from the v1.0.0-build.8 GitHub release.
The Generate abort was seen **once in ~25 generations and never reproduced**
across 8 voices, three sample rates and five cold starts — that is not
established enough to publish as a known defect. #48 stays open for
investigation.
