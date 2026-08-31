import EngineKit
import Foundation

/// Process physical-memory footprint (same figure Activity Monitor shows).
/// Thin alias over `EngineKit.ProcessFootprint`, which is where model loads
/// are measured -- one implementation, one number.
enum MemoryFootprint {
    static func currentGB() -> Double { ProcessFootprint.gigabytes }
}
