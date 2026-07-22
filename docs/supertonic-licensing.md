# SuperTonic 3 — licensing, attribution, and EULA pass-down

The `.supertonic` backend uses weights converted from **SuperTonic 3 by
Supertone Inc.** (https://huggingface.co/Supertone/supertonic-3), licensed
under the **BigScience Open RAIL-M License** (dated 2022-08-18). Open RAIL-M
is permissive on IP but carries **use-based restrictions (Attachment A)**
that every distributor MUST pass down to end users — including us
(License §5: "You shall require all of Your users who use the Model or a
Derivative of the Model to comply with the terms of this paragraph").

That is why `BackendID.supertonic.spec.needsLicenseAck == true`: like Fish,
the backend is gated behind an explicit in-app acknowledgement.

## Converted weights are MODIFIED FILES

The weights the app downloads (`tinytrashlabs/supertonic-3-mlx`) are
format-converted from the original ONNX exports (fp32, opset 19, the
`onnx/` dir of `Supertone/supertonic-3`): safetensors container, renamed
tensor keys, Conv axis order `[O,I,K] → [O,K,I]`, and the CFG scale (4.0) +
Euler step factored out of the graph into the runtime. Numerical values are
unchanged. The converted repo carries the LICENSE, a NOTICE describing the
modification, and Attachment A — any surface that credits the model should
also say the weights are modified (Open RAIL-M requires marking changed
files).

## In-app attribution string

The canonical string ships as `supertonicLicenseNotice` in
`Sources/StudioKit/Server/APITypes.swift` (already used by the API server's
403 response for an un-acked SuperTonic request):

> SuperTonic voices are powered by SuperTonic 3 by Supertone Inc.
> (huggingface.co/Supertone/supertonic-3), used under the BigScience Open
> RAIL-M license; the weights are format-converted (modified) for MLX. The
> license carries use restrictions that pass down to you: no unlawful use,
> no impersonation or deepfakes of real people without their consent, no
> harassment or defamation, no generating harmful disinformation, and no
> undisclosed machine-generated content. By enabling this backend you agree
> to these restrictions.

## EULA / license-surface pass-down clause (ready to drop in)

For the app's EULA / licenses screen (the full Attachment A, condensed to
its operative text — keep all thirteen items when surfacing "full terms",
e.g. by linking the LICENSE file in the weights repo):

> **SuperTonic 3 voices — Open RAIL-M use restrictions.** The SuperTonic
> voice model is licensed under the BigScience Open RAIL-M license, whose
> use restrictions apply to you and to anything you generate with it. You
> agree not to use the model or its output: (a) in violation of any law;
> (b) to exploit or harm minors; (c) to generate or spread verifiably false
> information intended to harm others; (d) to generate or disseminate
> personal identifiable information to harm an individual; (e) to present
> machine-generated content without clearly disclosing it is machine
> generated; (f) to defame, disparage, or harass others; (g) to impersonate
> any person — including voice deepfakes — without their consent; (h) for
> fully automated decision-making that adversely affects a person's legal
> rights or creates a binding obligation; (i)–(k) for any use that
> discriminates against or harms individuals or groups based on social
> behavior, personal characteristics, or legally protected categories;
> (l) to provide medical advice or interpret medical results; (m) for
> administration-of-justice, law-enforcement, immigration, or asylum
> profiling. Full license: BigScience Open RAIL-M (2022-08-18), included
> with the model download.

## Where this goes in the app (deferred — App/Views has uncommitted WIP)

Mirror the Fish Audio Research License ack path:

1. **Ack sheet** — `App/Views/SettingsView.swift` has `FishLicenseSheet`
   showing `fishLicenseNotice`. Add a SuperTonic equivalent (or generalize
   the sheet to take `licenseNotice(for:)` + a title). The confirm button
   should read "I Agree to the Use Restrictions" rather than the Fish
   "Personal Use" wording — Open RAIL-M permits commercial use; the gate is
   the Attachment A restrictions, not non-commerciality.
2. **Ack state** — `App/AppModel.swift` gates on a Fish-specific
   `didAckFishLicense` bool in ~6 places and always acks `.fishS2Pro`.
   Generalize to a per-backend ack set (persisted) so `.supertonic` gets
   its own ack and its own `engine.acknowledgeLicense(for: .supertonic)`.
3. **Settings caption** — `SettingsView` line ~158 appends
   "· research/personal license" when `needsLicenseAck`; SuperTonic should
   instead read something like "· Open RAIL-M use restrictions".

The engine (`GloamEngine`) and API server already enforce the ack; only the
UI strings/sheet/persistence remain.
