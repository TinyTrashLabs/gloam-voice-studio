// ReferenceStandard.swift
// EngineKit — what every reference meets on its way into a voice library.
//
// One entry point for both apps' library write sites, the pack bakers
// (`spike gvoice-build` saves through VoiceLibrary; `voice-level` rewrites
// packs and voices already on disk), so a rule added here reaches every
// voice however it arrived -- recorded, combined, imported or baked.

import Foundation
import GVoiceKit

public enum ReferenceStandard {
    /// `wav` with no cut-off ending (ReferenceTail), then at the loudness
    /// standard (RefLoudness). The order matters: the level is measured on
    /// the audio that is kept. Never throws; bytes neither step understands
    /// come back unchanged.
    public static func applied(to wav: Data) -> Data {
        RefLoudness.normalized(wav: ReferenceTail.trimmed(wav: wav))
    }
}
