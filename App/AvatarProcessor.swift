import AppKit
import Foundation

enum AvatarProcessor {
    /// Loads raw image data (PNG/JPEG/HEIC/etc.), center-crops to square,
    /// downscales to 256×256, and re-encodes as PNG. Returns nil on failure.
    static func makeAvatarPNG(from data: Data) -> Data? {
        guard let source = NSImage(data: data) else { return nil }
        let srcSize = source.size
        guard srcSize.width > 0, srcSize.height > 0 else { return nil }

        // Center-crop rect (shortest side)
        let side = min(srcSize.width, srcSize.height)
        let cropOrigin = CGPoint(
            x: (srcSize.width - side) / 2,
            y: (srcSize.height - side) / 2)
        let cropRect = CGRect(origin: cropOrigin, size: CGSize(width: side, height: side))

        // Draw into 256×256 bitmap
        let targetSize = CGSize(width: 256, height: 256)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        source.draw(in: CGRect(origin: .zero, size: targetSize),
                    from: cropRect,
                    operation: .copy,
                    fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }
}
