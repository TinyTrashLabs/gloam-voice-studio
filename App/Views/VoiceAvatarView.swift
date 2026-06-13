import SwiftUI

struct VoiceAvatarView: View {
    let slug: String
    let name: String
    let avatarURL: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url = avatarURL,
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                generatedAvatar
            }
        }
        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
        .accessibilityIdentifier("voice-avatar")
    }

    private var generatedAvatar: some View {
        let hue = slugHue(slug)
        let stop1 = Color(hue: hue, saturation: 0.55, brightness: 0.85)
        let stop2 = Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
                          saturation: 0.7, brightness: 0.7)
        return ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [stop1, stop2],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing))
            Text(monogram)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(Brand.fg)
        }
        .frame(width: size, height: size)
    }

    private var monogram: String {
        let source = name.isEmpty ? slug : name
        guard let first = source.unicodeScalars.first(where: {
            CharacterSet.letters.contains($0)
        }) else { return "?" }
        return String(first).uppercased()
    }

    /// Stable (non-randomized) hue derived from slug characters.
    /// Uses a simple rotate-accumulate over unicode scalars — deterministic
    /// across Swift runs (unlike hashValue which is randomized per process).
    private func slugHue(_ s: String) -> Double {
        var hash: UInt32 = 0
        for scalar in s.unicodeScalars {
            hash = (hash &<< 5) &+ hash &+ scalar.value
        }
        return Double(hash % 360) / 360.0
    }
}
