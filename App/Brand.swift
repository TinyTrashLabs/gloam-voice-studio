import AppKit
import SwiftUI

/// Native behind-window glass: blurs the desktop/windows behind this window,
/// the way Finder/Music sidebars do. SwiftUI's `Material` styles only blur
/// in-window content on macOS, so window glass needs an NSVisualEffectView.
/// Layer a Brand tint on top (`.background(tint).background(WindowGlass())`)
/// to keep the night palette while the desktop glows through.
struct WindowGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

enum Brand {
    // Night palette — the app icon's ground: violet-black, not teal-black.
    static let ink   = Color(red: 3/255,  green: 2/255,   blue: 9/255)    // #030209
    static let ink2  = Color(red: 10/255, green: 6/255,   blue: 22/255)   // #0a0616
    // Foreground
    static let fg     = Color(red: 246/255, green: 246/255, blue: 255/255) // #f6f6ff
    static let fgDim  = fg.opacity(0.62)
    static let fgFaint = fg.opacity(0.34)
    // Accents — the icon's bars, bottom to top: cyan → violet → hot pink.
    static let accent = Color(red: 63/255,  green: 220/255, blue: 255/255) // #3fdcff
    static let violet = Color(red: 138/255, green: 60/255,  blue: 255/255) // #8a3cff
    static let peak   = Color(red: 255/255, green: 42/255,  blue: 138/255) // #ff2a8a
    /// The bar tips catch a warm highlight in the icon.
    static let ember  = Color(red: 255/255, green: 122/255, blue: 80/255)  // #ff7a50
    // Brand gradient (simulating 120° as topLeading → bottomTrailing)
    static var gradient: LinearGradient {
        LinearGradient(
            colors: [accent, violet, peak],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// One source of truth for the artwork shown by macOS and inside the app.
    /// Loading the bundle resource directly also avoids a stale LaunchServices
    /// icon being reflected back through `NSApplication.applicationIconImage`.
    static var appIcon: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

// MARK: - BrandMark

/// The exact four-bar app artwork, shared with the Dock icon so the lockup can
/// never drift to a hand-drawn approximation of the current logo.
struct BrandMark: View {
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let icon = Brand.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "waveform")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Brand.gradient)
                    .padding(size * 0.18)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - BrandLockup

struct BrandLockup: View {
    var body: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30)

            VStack(alignment: .leading, spacing: 1) {
                // Wordmark: GLOAM in white + .FM in gradient
                HStack(spacing: 0) {
                    Text("GLOAM")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Brand.fg)
                    Text(".FM")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Brand.gradient)
                }
                .tracking(1.5)
                .textCase(.uppercase)

                // Subtitle
                Text("VOICE STUDIO")
                    .font(.system(size: 9, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(Brand.accent)
            }
        }
    }
}
