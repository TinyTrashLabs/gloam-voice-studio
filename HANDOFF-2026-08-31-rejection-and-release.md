# Handoff — App Store rejection, build 9 release, branch consolidation (2026-08-31)

Supersedes `HANDOFF.md` (2026-08-30 night), which is now stale: it describes
`chore/studio-build-7` as unpushed, and that branch has since been merged to
`main` and deleted.

Branch: **`main`** at `32f524dc`. This repo now has exactly one remote branch.

---

## 1. App Store rejection — REPLIED, AWAITING APPLE

**Status: blocked on Apple. Nothing to build.**

App `6786521434`, version 1.0.0, submission `8ef788d8-55f8-4b4c-9fe4-5e288489e64e`.
Rejected under **2.4.5 Performance: Hardware Compatibility (macOS)** by an
automated scan:

> the app includes the `com.apple.security.network.server` entitlement but does
> not appear to have matching functionality

### The entitlement is genuinely required — do not remove it

Under the App Sandbox, **binding a listening socket requires
`network.server` even on loopback**. `network.client` is not sufficient. The
app really does listen:

- `Sources/StudioKit/Server/LocalAPIServer.swift:20` — Hummingbird `Application`
  on `NWListener`, default host `127.0.0.1`
- `App/AppModel.swift:1301` — binds `0.0.0.0` only behind the LAN toggle
- `App/Views/SettingsView.swift:212` — the whole **Settings → API Server** tab
- `Sources/StudioKit/Server/MCPRoute.swift` — MCP endpoint at `/mcp`
- `store/screenshots/mac/en-US/05-api-server.png` — it is in the store listing

**Why the scan missed it:** `App/AppModel.swift:539` reads
`defaults.bool(forKey: "serverEnabled")` → **off by default**. A launched-and-idle
app never opens a port, so a dynamic analysis sees no listener. That is the whole
rejection, and the repro steps are the part that answers it.

### What was done

- **App Review Information notes rewritten** and pushed via
  `asc review details-update --id 3ec2e255-e23d-461e-b615-99655472fbac`.
  Now lead with the API server and a 6-step repro. 3,998 chars — **the field caps
  at 4,000**, so any further edit has to trim something.
- **Resolution Center reply posted** (2,641 chars), visible in the thread as
  `david freeman · 2026-08-31 7:08 PM`. Drafts kept at
  `scratchpad/resolution-reply.txt` and `scratchpad/review-notes.txt`.

### Next step when Apple replies

Build 9 is already `VALID` and attached, so **if they accept, nothing needs
rebuilding or re-uploading** — the submission just proceeds.

If they bounce it on the same automated scan again, the next lever is a review
attachment: `asc review attachments-upload --review-detail 3ec2e255-...` with a
screen recording of the toggle going green and `curl /health` answering.

**`asc` has no Resolution Center command at all** — replying is web-UI only.
Use the user's own Chrome (never Playwright's profile) at
`https://appstoreconnect.apple.com/apps/6786521434/distribution/reviewsubmissions/details/8ef788d8-55f8-4b4c-9fe4-5e288489e64e`
→ "Reply to App Review".

---

## 2. Build 9 released on GitHub

<https://github.com/TinyTrashLabs/gloam-voice-studio/releases/tag/v1.0.0-build.9>

`GloamVoiceStudio-1.0.0-macOS.zip`, 53.7 MB, universal (arm64 + x86_64), marked
Latest. Developer ID — separate signing path from the MAS `.pkg` that went to ASC.

Verified before publishing, not inferred from a zero exit code:

```
spctl --assess --type execute -vvv → accepted
                                     source=Notarized Developer ID
                                     origin=Developer ID Application: Tiny Trash Labs LLC (UT233385J9)
xcrun stapler validate            → The validate action worked!
CFBundleShortVersionString/Version → 1.0.0 / 9
```

Delta over the build 8 release is the icon work only — `67e4892b`
(full-resolution `AppIcon.icns`) and `0d94c613` (icon phase under an archive
build's sandbox). The other six commits were docs.

---

## 3. New: one-command release

`scripts/release-tagged.sh` (committed `e534116c`).

```bash
# bump CURRENT_PROJECT_VERSION in project.yml, commit, then:
bash scripts/release-tagged.sh              # -> tag v<marketing>-build.<n>, build, notarize, publish
bash scripts/release-tagged.sh --dry-run    # everything except tag + publish
bash scripts/release-tagged.sh --allow-off-main
```

Three things it fixes, each of which bit us this session:

1. **Version comes from `project.yml`, which is committed.** The `.xcodeproj` it
   generates is gitignored, so a build number living only there could never be
   reproduced on another machine — that is what made "redo the bump wherever you
   build" a standing chore.
2. **Build → notarize → assert Gatekeeper acceptance happens BEFORE the tag is
   pushed or the release created.** A failed build leaves nothing half-published.
3. **It fetches its own Infisical token first.** The CLI has no interactive login
   on this Mac; without a token `infisical secrets get` returns its region-picker
   TUI escape codes instead of failing, which only surfaces much later as an
   unreadable `.p12`. The script validates token length before proceeding.

`--allow-off-main` exists because build 8 shipped from a branch. That should stay
the exception — it is no longer needed, see below.

---

## 4. Branch consolidation — this repo now ships from `main`

**Every App Store submission before today was cut from `chore/studio-build-7`,
never from `main`.** `main` had been 15 commits behind since 2026-08-29. That is
fixed: PR #49 merged, `main` is `32f524dc`, and `v1.0.0-build.9` is an ancestor
of `main`, so the existing release *is* a main release.

Deleted 9 stale remote branches and 10 local ones across two passes.

**The lesson worth keeping:** six branches showed as "unmerged" by
`git branch --merged` *and* by `git cherry`, but their work was already in the
shipped binary — it had landed via rebase/squash under different SHAs. Ancestry
and patch-id both miss that. The reliable test was **checking whether the
feature's symbols exist in the built tree**:

| Feature | In build 9 | Branch that "owned" it |
|---|---|---|
| SuperTonic backend | 16 files | `feat/supertonic-mlx` |
| Pocket TTS | 9 files | `feat/gvoice-format-spec` |
| LuxTTS | 13 files | `feat/gvoice-format-spec` |
| .gvoice packs | 21 files + `packs/` | `feat/gvoice-format-spec` |
| Accessibility labels | 10 files | `feat/a11y-audio-drop` |
| Chatterbox exaggeration ceiling | 3 files | `chatterbox-exaggeration-ceiling` |
| App Group sharing | entitlements + `sync-app-group.sh` | `feat/shared-app-group` |

The one file that looked unique, `App/StoragePaths.swift`, had been deliberately
deleted by `d44365f5` ("one storage root"); the old branch simply predated that
refactor.

SHAs recorded before deletion, recoverable from reflog:

```
chatterbox-exaggeration-ceiling  9fca9448
feat/a11y-audio-drop             e10c1b20
feat/supertonic-mlx              9c44e993
feat/gvoice-format-spec          a2592c65
feat/hf-snapshot-byte-progress   55f0fbd9
feat/shared-app-group            1a468fdb
```

---

## 5. ⚠️ `feat/supertonic-voice-bake` is company IP — DO NOT PUSH

**This repo is PUBLIC.**

`feat/supertonic-voice-bake` (`a4a40e48`, 4 tip commits) is SuperTonic **offline
voice baking**, and David has ruled it proprietary — it must not be open-sourced.
It is local-only on this Mac, verified absent from the public remote.

Not shipped, exists nowhere else:

```
a4a40e48  BackendSpec.supportsOfflineBake      → 0 files in build
a6360c5b  per-voice supertonic.json            → 0 files in build
8daeb175  SuperTonic style-file validator      → Sources/StudioKit/SupertonicStyleFile.swift MISSING
9c633c7c  VoiceMeta SuperTonic markers         → MISSING
```

**Two standing risks, both unaddressed:**

1. It is only unpushed by luck. A `git push --all`, or a future "tidy the
   branches" pass that does not read this file, publishes company IP to a public
   repo. **Never run `git push --all` in this repo.**
2. **It is the only copy that exists.** A disk failure loses it. It wants a
   private remote or a private repo, not an unpushed local branch — that decision
   is still open.

(Note the shipped SuperTonic *backend* is public and fine. It is the **bake**
work that is restricted.)

---

## Open / next

- **Apple's response** on the entitlement reply — the only thing blocking 1.0.0.
- **Give the IP branch a private home.** See §5. Open decision.
- **No build 10 needed.** Build 9 is released and is on `main`. A new release
  would be code-identical.
- **Separate repo, still open:** `../gloam-dj` has
  `HANDOFF-2026-08-30-park-regression.md`. Its "best next task" —
  making `resumeFromStaleHold` preserve its plan the way `parkAfterInterruption`
  now does — was selected this session but **never started**; we switched to the
  rejection instead. That branch (`test/park-and-tz`) is still unmerged to
  `preview`, and two items there remain unverified by eye on David's phone.

## Reference

- ASC app id `6786521434`, bundle `fm.gloam.studio`, team `UT233385J9`
- `asc status --app 6786521434` for a one-screen state read
- Notarized build: `source scripts/stage-devid-signing.sh && fastlane build_notarized`
  (source, don't execute — the exported env has to reach fastlane)
- Infisical is **self-hosted and tailnet-only** (`infisical.tinytrashlabs.com`).
  This is why a GitHub-hosted CI runner cannot sign, and why the release path is
  a local script rather than a workflow.
