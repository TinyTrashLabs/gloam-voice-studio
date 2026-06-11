/// Named emotion levels, raw values matching the Python engine and the studio UI.
public enum Emotion: String, CaseIterable, Sendable, Codable {
    case flat, neutral, warm, excited, hype

    /// Chatterbox (regular) `exaggeration` knob. Turbo ignores it upstream —
    /// emotion rides the reference clip there.
    public var chatterboxExaggeration: Float {
        switch self {
        case .flat: 0.2
        case .neutral: 0.5
        case .warm: 0.6
        case .excited: 0.85
        case .hype: 1.0
        }
    }

    /// Fish sampling temperature. 0.7 is the model default; hotter sampling adds
    /// delivery dynamics (measured upstream: p95 frame energy +25% at 1.0).
    public var fishTemperature: Float {
        switch self {
        case .flat: 0.6
        case .neutral: 0.7
        case .warm: 0.8
        case .excited: 0.9
        case .hype: 1.0
        }
    }
}
