#if os(iOS)
import SwiftUI
import UIKit

/// Move and scale: the Contacts-style circle crop. The photo sits under a
/// dimmed mask with a clear circle; pan and pinch until the face is where
/// you want it, then Choose. What comes out is the square the circle
/// covered, which the store's `setAvatar` then resamples to the pack's
/// 256×256. Nothing is cropped for you: the picker hands over the whole
/// photo and this is the only place the framing is decided.
struct AvatarCropView: View {
    @Environment(\.voiceEditorTheme) private var t
    let image: UIImage
    let onChoose: (UIImage) -> Void
    let onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private static let maxScale: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 48
            let radius = side / 2
            let base = side / min(image.size.width, image.size.height)
            let liveScale = clampedScale(scale * pinch)
            let shown = CGSize(width: image.size.width * base * liveScale,
                               height: image.size.height * base * liveScale)
            let liveOffset = clamped(CGSize(width: offset.width + drag.width,
                                            height: offset.height + drag.height),
                                     shown: shown, radius: radius)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .position(x: center.x + liveOffset.width, y: center.y + liveOffset.height)
                // Dim everything but the circle.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                            width: side, height: side))
                }
                .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                Circle()
                    .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: side, height: side)
                    .position(center)
                    .allowsHitTesting(false)

                VStack {
                    Text("MOVE AND SCALE")
                        .font(t.console(11, .medium)).tracking(2)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.top, 18)
                    Spacer()
                    HStack {
                        Button("Cancel", action: onCancel)
                            .font(t.sans(17)).foregroundStyle(.white)
                        Spacer()
                        Button("Choose") {
                            onChoose(render(shown: shown, offset: liveOffset, radius: radius))
                        }
                        .font(t.sans(17, .semibold)).foregroundStyle(t.accent)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset = clamped(CGSize(width: offset.width + value.translation.width,
                                                height: offset.height + value.translation.height),
                                         shown: shown, radius: radius)
                    }
                    .simultaneously(with:
                        MagnifyGesture()
                            .updating($pinch) { value, state, _ in state = value.magnification }
                            .onEnded { value in
                                scale = clampedScale(scale * value.magnification)
                                let s = CGSize(width: image.size.width * base * scale,
                                               height: image.size.height * base * scale)
                                offset = clamped(offset, shown: s, radius: radius)
                            })
            )
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    private func clampedScale(_ s: CGFloat) -> CGFloat { min(max(s, 1), Self.maxScale) }

    /// The circle must stay fully covered by the photo.
    private func clamped(_ o: CGSize, shown: CGSize, radius: CGFloat) -> CGSize {
        let maxX = max(0, shown.width / 2 - radius)
        let maxY = max(0, shown.height / 2 - radius)
        return CGSize(width: min(max(o.width, -maxX), maxX),
                      height: min(max(o.height, -maxY), maxY))
    }

    /// The square under the circle, at up to 512px. The draw bakes the
    /// photo's orientation in, so the crop maths work in upright points.
    private func render(shown: CGSize, offset: CGSize, radius: CGFloat) -> UIImage {
        let out: CGFloat = 512
        let ratio = out / (radius * 2)                      // output px per screen pt
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: out, height: out),
                                               format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return renderer.image { _ in
            // Image origin relative to the circle's top-left, in screen points.
            let originX = (-shown.width / 2 + offset.width) + radius
            let originY = (-shown.height / 2 + offset.height) + radius
            image.draw(in: CGRect(x: originX * ratio, y: originY * ratio,
                                  width: shown.width * ratio, height: shown.height * ratio))
        }
    }
}
#endif
