# Research: SuperTonic offline voice bake (archived)

Parked, obsolete work from July 2026, kept for reference. It is **not built or used**.

It was branch `revisit/supertonic-voice-bake` (tip `a4a40e48`, forked from
`eab28f25`). That branch was deleted on 2026-10-04 and its commits are kept here as patches
and as the tag `archive/supertonic-voice-bake`. To look at the original code:

    git checkout archive/supertonic-voice-bake

Or apply the patches to a scratch branch at the fork point:

    git switch -c scratch eab28f25 && git am research/supertonic-voice-bake/patches/*.patch

## What it held

- feat(engine): BackendSpec.supportsOfflineBake (true for SuperTonic)
- feat(voices): store/import/invalidate per-voice supertonic.json
- feat(voices): SuperTonic style-file validator (dims/finite/unit-rows, tolerant)
- feat(voices): VoiceMeta SuperTonic markers (String, tolerant decode)
- build(engine): repin mlx-audio-swift to the merged SuperTonic commit
- refactor(app): per-backend license acks — Fish and SuperTonic are distinct licenses
- feat(app): make SuperTonic selectable — pickers, studio preset UI, download size
- fix(engine): use canonical lowercase HF namespace for SuperTonic weights
- docs(engine): SuperTonic Open RAIL-M attribution + license notice
- test(engine): SuperTonic synthesis smoke + preset validation
- feat(engine): add SuperTonic backend spec + preset voices
- build(engine): pin mlx-audio-swift to the SuperTonic fork head

## What main has since

Main later gained a SuperTonic backend and its licensing doc in another form. What only this branch has:

- the `BackendSpec.supportsOfflineBake` flag
- per-voice `supertonic.json` storage, import and invalidation
- the SuperTonic style-file validator (dims, finite values, unit rows)
