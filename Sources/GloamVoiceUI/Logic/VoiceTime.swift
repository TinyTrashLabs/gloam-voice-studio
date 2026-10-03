import Foundation

/// "m:ss", the way the editor labels a recording's length.
public enum VoiceTime {
    public static func string(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
