import SwiftUI

/// The editor's colours and type, injected rather than hard-wired so a host
/// that is not the Studio app can wear its own. `.gloam` is the Studio app's
/// palette (the app icon's: teal-black ground, bars cyan → violet → hot pink)
/// and is what the editor uses when nothing is injected.
///
/// `textScale` is the host's text-size preference (the Studio app's Dynamic
/// Type + in-app size); the identity by default.
public struct VoiceEditorTheme {
    // Ground
    public var ink: Color
    public var ink2: Color
    // Foreground
    public var fg: Color
    public var fgDim: Color
    public var fgFaint: Color
    // Accents
    public var accent: Color
    public var violet: Color
    public var peak: Color
    // Panels
    public var panel: Color
    public var panelStroke: Color
    /// Maps a nominal point size to the one drawn.
    public var textScale: @Sendable (CGFloat) -> CGFloat

    public init(ink: Color, ink2: Color, fg: Color, fgDim: Color, fgFaint: Color,
                accent: Color, violet: Color, peak: Color, panel: Color, panelStroke: Color,
                textScale: @escaping @Sendable (CGFloat) -> CGFloat = { $0 }) {
        self.ink = ink; self.ink2 = ink2
        self.fg = fg; self.fgDim = fgDim; self.fgFaint = fgFaint
        self.accent = accent; self.violet = violet; self.peak = peak
        self.panel = panel; self.panelStroke = panelStroke
        self.textScale = textScale
    }

    /// The Studio app's `Brand`, value for value.
    public static var gloam: VoiceEditorTheme {
        let fg = Color(red: 246/255, green: 246/255, blue: 255/255)               // #f6f6ff
        return VoiceEditorTheme(
            ink: Color(red: 2/255, green: 18/255, blue: 26/255),                  // #02121a
            ink2: Color(red: 7/255, green: 35/255, blue: 47/255),                 // #07232f
            fg: fg, fgDim: fg.opacity(0.62), fgFaint: fg.opacity(0.34),
            accent: Color(red: 76/255, green: 239/255, blue: 253/255),            // #4ceffd
            violet: Color(red: 174/255, green: 105/255, blue: 252/255),           // #ae69fc
            peak: Color(red: 254/255, green: 58/255, blue: 139/255),              // #fe3a8b
            panel: Color(red: 10/255, green: 44/255, blue: 58/255).opacity(0.72),
            panelStroke: Color(red: 76/255, green: 239/255, blue: 253/255).opacity(0.26))
    }

    public var gradient: LinearGradient {
        LinearGradient(colors: [accent, violet, peak], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Page ground. Flat rather than a dusk gradient: one colour, the
    /// gradient belongs to the bars.
    public var ground: some View {
        LinearGradient(colors: [ink2, ink], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    // Every size goes through `textScale`, as the Studio app's fonts do.
    public func masthead(_ size: CGFloat) -> Font {
        .system(size: textScale(size), weight: .semibold, design: .serif)
    }
    public func mastheadItalic(_ size: CGFloat) -> Font {
        .system(size: textScale(size), weight: .medium, design: .serif).italic()
    }
    public func console(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: textScale(size), weight: weight, design: .monospaced)
    }
    /// System sans for sentence-length body copy.
    public func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: textScale(size), weight: weight)
    }
}

private struct VoiceEditorThemeKey: EnvironmentKey {
    static var defaultValue: VoiceEditorTheme { .gloam }
}

extension EnvironmentValues {
    public var voiceEditorTheme: VoiceEditorTheme {
        get { self[VoiceEditorThemeKey.self] }
        set { self[VoiceEditorThemeKey.self] = newValue }
    }
}
