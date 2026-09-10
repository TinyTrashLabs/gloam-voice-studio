import CoreGraphics
import ImageIO
import XCTest
@testable import GVoiceKit

final class AvatarImageTests: XCTestCase {
    /// A flat-colour image of any size, PNG-encoded, for tests that need
    /// something ImageIO will decode. Deterministic, so a round trip can
    /// compare bytes.
    static func solidPNG(width: Int, height: Int) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.9, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testLandscapeIsCentreCroppedToTheStandardSquare() throws {
        let png = try XCTUnwrap(AvatarImage.png(from: try Self.solidPNG(width: 1200, height: 400)))
        XCTAssertTrue(AvatarImage.isPNG(png))
        let size = try XCTUnwrap(AvatarImage.pixelSize(of: png))
        XCTAssertEqual(size.width, AvatarImage.side)
        XCTAssertEqual(size.height, AvatarImage.side)
    }

    func testPortraitIsCentreCroppedToTheStandardSquare() throws {
        let png = try XCTUnwrap(AvatarImage.png(from: try Self.solidPNG(width: 300, height: 900)))
        let size = try XCTUnwrap(AvatarImage.pixelSize(of: png))
        XCTAssertEqual(size.width, AvatarImage.side)
        XCTAssertEqual(size.height, AvatarImage.side)
    }

    func testASmallImageIsScaledUpRatherThanRejected() throws {
        let png = try XCTUnwrap(AvatarImage.png(from: try Self.solidPNG(width: 40, height: 60)))
        let size = try XCTUnwrap(AvatarImage.pixelSize(of: png))
        XCTAssertEqual(size.width, AvatarImage.side)
        XCTAssertEqual(size.height, AvatarImage.side)
    }

    func testGarbageIsNil() {
        XCTAssertNil(AvatarImage.png(from: Data("not an image".utf8)))
        XCTAssertNil(AvatarImage.png(from: Data()))
        XCTAssertFalse(AvatarImage.isPNG(Data("not an image".utf8)))
    }
}
