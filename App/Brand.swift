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
}

// MARK: - BrandMark

/// The app icon's five glowing bars, drawn live so it stays crisp at any size
/// and picks up Brand's colours rather than a baked PNG's.
struct BrandMark: View {
    var size: CGFloat = 32

    var body: some View {
        Canvas { ctx, _ in
            let scale = size / 32
            // Bars in a 32-grid: x centre and height, all standing on one
            // baseline at y = 26 like the icon.
            let bars: [(x: Double, h: Double)] = [
                (5.5, 9), (11, 15), (16.5, 21), (22, 14), (27.5, 8),
            ]
            let baseline = 26.0 * scale
            let barW = 3.6 * scale

            // Baseline glow: a soft cyan lit strip the bars stand on.
            let glowRect = CGRect(x: 1 * scale, y: baseline - 0.6 * scale,
                                  width: 30 * scale, height: 1.2 * scale)
            var glow = ctx
            glow.addFilter(.blur(radius: 1.2 * scale))
            glow.fill(Path(roundedRect: glowRect, cornerRadius: 0.6 * scale),
                      with: .color(Brand.accent.opacity(0.9)))

            for bar in bars {
                let barRect = CGRect(
                    x: (bar.x * scale) - barW / 2,
                    y: baseline - bar.h * scale,
                    width: barW,
                    height: bar.h * scale)
                let barPath = Path(roundedRect: barRect, cornerRadius: barW / 2)
                let fill = GraphicsContext.Shading.linearGradient(
                    Gradient(stops: [
                        .init(color: Brand.ember,  location: 0.0),
                        .init(color: Brand.peak,   location: 0.18),
                        .init(color: Brand.violet, location: 0.58),
                        .init(color: Brand.accent, location: 1.0),
                    ]),
                    startPoint: CGPoint(x: barRect.midX, y: barRect.minY),
                    endPoint: CGPoint(x: barRect.midX, y: barRect.maxY))
                // Halo first, then the solid pill on top.
                var halo = ctx
                halo.addFilter(.blur(radius: 1.6 * scale))
                halo.opacity = 0.55
                halo.fill(barPath, with: fill)
                ctx.fill(barPath, with: fill)
            }
        }
        .frame(width: size, height: size)
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
