// ReferenceStandard and ReferenceTail moved to GVoiceKit so MLX-free targets
// (GVoiceProductionKit, QwenANE) can use them. These aliases keep every
// `import EngineKit` caller compiling unchanged. (A blanket
// `@_exported import GVoiceKit` would make JSONValue ambiguous against
// MLXLMCommon's.)
import GVoiceKit

public typealias ReferenceStandard = GVoiceKit.ReferenceStandard
public typealias ReferenceTail = GVoiceKit.ReferenceTail
