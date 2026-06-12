import SwiftUI

enum Brand {
    // Night palette
    static let ink   = Color(red: 4/255,  green: 20/255,  blue: 26/255)   // #04141a
    static let ink2  = Color(red: 6/255,  green: 26/255,  blue: 34/255)   // #061a22
    // Foreground
    static let fg     = Color(red: 246/255, green: 249/255, blue: 255/255) // #f6f9ff
    static let fgDim  = fg.opacity(0.62)
    static let fgFaint = fg.opacity(0.34)
    // Accents
    static let accent = Color(red: 122/255, green: 223/255, blue: 230/255) // #7adfe6
    static let peak   = Color(red: 255/255, green: 51/255,  blue: 128/255) // #ff3380
    // Brand gradient (simulating 120° as topLeading → bottomTrailing)
    static var gradient: LinearGradient {
        LinearGradient(
            colors: [accent, peak],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - BrandMark

struct BrandMark: View {
    var size: CGFloat = 32

    var body: some View {
        Canvas { ctx, _ in
            let scale = size / 32
            let cornerRadius = 8.0 * scale

            // Outer rounded rect (near-transparent fill, gradient stroke)
            let outerRect = CGRect(x: 1.5 * scale, y: 1.5 * scale,
                                   width: 29 * scale, height: 29 * scale)
            let outerPath = Path(roundedRect: outerRect, cornerRadius: cornerRadius)

            // Fill with very slight tint
            ctx.fill(outerPath, with: .color(.white.opacity(0.04)))

            // Draw gradient stroke by clipping a wide stroke
            ctx.stroke(outerPath,
                       with: .linearGradient(
                           Gradient(colors: [Brand.accent, Brand.peak]),
                           startPoint: CGPoint(x: 0, y: 0),
                           endPoint: CGPoint(x: size, y: size)),
                       lineWidth: 1.5 * scale)

            // 4 EQ bars: (x, width, height, y) in 32-grid
            // x positions: 7.5, 12.5, 17.5, 22.5
            // heights: 8, 18, 12, 5
            // y: 12, 7, 10, 13.5 (top of bar)
            // width: 2.6, corner radius 1.3
            let bars: [(x: Double, h: Double, y: Double)] = [
                (7.5, 8,  12),
                (12.5, 18, 7),
                (17.5, 12, 10),
                (22.5, 5,  13.5)
            ]
            let barW = 2.6 * scale
            let barR = 1.3 * scale

            for bar in bars {
                let barRect = CGRect(
                    x: (bar.x - 1.3) * scale,
                    y: bar.y * scale,
                    width: barW,
                    height: bar.h * scale)
                let barPath = Path(roundedRect: barRect, cornerRadius: barR)
                ctx.fill(barPath,
                         with: .linearGradient(
                             Gradient(colors: [Brand.accent, Brand.peak]),
                             startPoint: CGPoint(x: barRect.midX, y: barRect.minY),
                             endPoint: CGPoint(x: barRect.midX, y: barRect.maxY)))
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
