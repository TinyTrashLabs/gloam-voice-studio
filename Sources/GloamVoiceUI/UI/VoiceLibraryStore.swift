import Combine
import Foundation
import GVoiceKit

/// Which parts of the editor a store can back. A section whose feature is
/// absent is not drawn, so a host with a thin voice model (the radio app has
/// no takes, no avatars, no loudness trim) gets an editor that only shows what
/// it can save.
public struct VoiceLibraryFeatures: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Name and notes (`VoiceMeta.name` / `.notes`).
    public static let notes = VoiceLibraryFeatures(rawValue: 1 << 0)
    /// A photo for the voice (`setAvatar` / `removeAvatar`).
    public static let avatars = VoiceLibraryFeatures(rawValue: 1 << 1)
    /// Takes: the list, record another, import, rebuild the master on Save.
    public static let takes = VoiceLibraryFeatures(rawValue: 1 << 2)
    /// "Clean up recording" (`cleanReference`).
    public static let cleanup = VoiceLibraryFeatures(rawValue: 1 << 3)
    /// The curated reference window (`setWindow` / `clearWindow`).
    public static let referenceWindow = VoiceLibraryFeatures(rawValue: 1 << 4)
    /// Acted emotion versions (`addVariant` / `deleteVariant`).
    public static let emotionVersions = VoiceLibraryFeatures(rawValue: 1 << 5)
    /// The voice's own delivery pace (`pace(for:)` / `setPace`).
    public static let pace = VoiceLibraryFeatures(rawValue: 1 << 6)
    /// Loudness trim in dB (`VoiceMeta.gain` / `setGain`).
    public static let gain = VoiceLibraryFeatures(rawValue: 1 << 7)
    /// Share as a `.gvoice` (`packExport`).
    public static let packShare = VoiceLibraryFeatures(rawValue: 1 << 8)
    /// Read-only: per-engine renditions the pack carries.
    public static let renditions = VoiceLibraryFeatures(rawValue: 1 << 9)
    /// Read-only: the pack's provenance.
    public static let provenance = VoiceLibraryFeatures(rawValue: 1 << 10)
    /// The voice's character (`VoiceMeta.persona`): who it is, tagline, catchphrases, color. Apps
    /// interpret it (radio: the host). Opt-in, not in `.all`, so a library without hosts never shows it.
    public static let persona = VoiceLibraryFeatures(rawValue: 1 << 11)

    /// What the Studio app's store backs: everything.
    public static let all: VoiceLibraryFeatures = [
        .notes, .avatars, .takes, .cleanup, .referenceWindow, .emotionVersions,
        .pace, .gain, .packShare, .renditions, .provenance,
    ]
}

/// A store that cannot do what the editor asked. Thrown by the default
/// implementations of the optional operations below; the editor never calls
/// one whose `VoiceLibraryFeatures` flag the store did not set.
public struct VoiceEditorUnsupported: Error, LocalizedError {
    public let operation: String
    public init(_ operation: String) { self.operation = operation }
    public var errorDescription: String? { "This voice library can't \(operation)." }
}

/// What the voice editor needs from a voice library. The Studio app's
/// `VoiceStore` conforms; so can the radio app's `UserVoiceStore` (resident,
/// read-only voices answer `canDelete == false`; its `.variantof` markers are
/// `Voice.variantKeys`; a sync tombstone is written inside `delete`).
///
/// The required core is what every voice has: a name, a reference clip, the
/// words it says. Everything else has a default that does nothing or throws
/// `VoiceEditorUnsupported`, and `features` says which of those the editor may
/// offer.
///
/// All operations are `@MainActor` and synchronous, as the Studio store is:
/// they are file writes small enough to run under a tap. The two that are not
/// (rendering a check, transcribing) are `VoiceEditorCapabilities`.
@MainActor
public protocol VoiceLibraryStore: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    // MARK: required

    /// Base voices, in display order. Emotion variants hang off
    /// `Voice.variantKeys` and are not listed.
    var voices: [Voice] { get }

    /// The words the voice's reference says: the curated window's when it has
    /// one, else the master's. Nil when the voice has no reference.
    func referenceText(of slug: String) -> String?
    /// The master recording, whether or not a window sits in front of it.
    func masterURL(of slug: String) -> URL?
    /// What the engine listens to: the window's audio when there is one, else the master.
    func referenceURL(of slug: String) -> URL?

    /// Edit the stored metadata (name, notes) and republish.
    func update(_ slug: String, _ mutate: (inout VoiceMeta) -> Void) throws
    /// Languages the voice speaks (BCP-47), its default first. The Character section offers a
    /// language picker when there is more than one.
    func languages(of slug: String) -> [String]
    /// The words the reference says, corrected in the editor.
    func updateTranscript(of voice: Voice, _ text: String) throws

    // MARK: optional with defaults

    var features: VoiceLibraryFeatures { get }

    /// False for a resident, read-only voice: the editor draws no Delete.
    func canDelete(_ voice: Voice) -> Bool
    /// Remove the voice and its variants. A synced store records its tombstone here.
    func delete(_ voice: Voice)

    /// The emotions the editor offers to record. Defaults to Studio's five.
    var emotionOptions: [EmotionOption] { get }

    /// The master's length, for deciding whether a window is worth offering.
    func masterSeconds(of slug: String) -> Double?
    /// Per-engine files the pack carries: engine id → file name → URL.
    func engineFiles(of slug: String) -> [String: [String: URL]]

    // Delivery
    /// The voice's own pace; 1.0 when unset. `nil`-pace stores return 1.0.
    func pace(for voice: Voice) -> Double
    func setPace(of voice: Voice, _ pace: Double) throws
    /// The range the Pace slider offers. Studio's is a narrow 0.75-1.35; a host
    /// whose voices are paced over a wider range (the radio's 0.6-2.2) says so.
    var paceRange: ClosedRange<Double> { get }
    func setGain(of voice: Voice, _ db: Double) throws

    // Reference recording
    /// Trim the silence off both ends of the master and level the speech, in place.
    func cleanReference(of voice: Voice) throws
    /// The master becomes the noise-cleaned version a voice check picked (24 kHz samples).
    func replaceMasterWithCleaned(of voice: Voice, samples: [Float]) throws

    // Avatar
    func setAvatar(_ slug: String, imageData: Data) throws
    func removeAvatar(_ slug: String) throws

    // Takes
    func takes(of voice: Voice) -> VoiceTakes
    func takeURL(of slug: String, id: Int) -> URL
    @discardableResult
    func addTake(to voice: Voice, clip: URL, transcript: String, origin: VoiceTake.Origin) throws -> VoiceTake
    func deleteTake(from voice: Voice, id: Int) throws
    func updateTake(of voice: Voice, id: Int, transcript: String) throws
    /// The master, rebuilt from every take; clears the stale flag.
    func rebuildMaster(of voice: Voice) throws

    // Reference window
    func window(of slug: String) -> ReferenceWindowMeta?
    func setWindow(of voice: Voice, samples: [Float], text: String,
                   derivedFrom: ReferenceWindowMeta.DerivedFrom) throws
    func clearWindow(of voice: Voice) throws

    // Emotion versions
    @discardableResult
    func addVariant(of voice: Voice, key: String, clip: URL, transcript: String) throws -> String
    func deleteVariant(of voice: Voice, key: String)

    // Sharing
    /// Builds the voice's `.gvoice` off the main actor: the returned closure
    /// runs on a background task. Nil when the voice cannot be shared.
    func packExport(for voice: Voice, includeSource: Bool) -> (@Sendable () throws -> Data)?
}

public extension VoiceLibraryStore {
    func languages(of slug: String) -> [String] { ["en"] }
}

extension VoiceLibraryStore {
    public var features: VoiceLibraryFeatures { .all }
    public func canDelete(_ voice: Voice) -> Bool { true }
    public var emotionOptions: [EmotionOption] { EmotionOption.studio }

    public func masterSeconds(of slug: String) -> Double? { masterURL(of: slug).flatMap(VoiceAudio.seconds(of:)) }
    public func engineFiles(of slug: String) -> [String: [String: URL]] { [:] }

    public func pace(for voice: Voice) -> Double { 1.0 }
    public func setPace(of voice: Voice, _ pace: Double) throws { throw VoiceEditorUnsupported("set a pace") }
    public var paceRange: ClosedRange<Double> { 0.75...1.35 }
    public func setGain(of voice: Voice, _ db: Double) throws { throw VoiceEditorUnsupported("set a loudness trim") }

    public func cleanReference(of voice: Voice) throws { throw VoiceEditorUnsupported("clean up a recording") }
    public func replaceMasterWithCleaned(of voice: Voice, samples: [Float]) throws {
        throw VoiceEditorUnsupported("replace a recording")
    }

    public func setAvatar(_ slug: String, imageData: Data) throws { throw VoiceEditorUnsupported("set a photo") }
    public func removeAvatar(_ slug: String) throws { throw VoiceEditorUnsupported("remove a photo") }

    public func takes(of voice: Voice) -> VoiceTakes { VoiceTakes() }
    public func takeURL(of slug: String, id: Int) -> URL { URL(fileURLWithPath: "/dev/null") }
    @discardableResult
    public func addTake(to voice: Voice, clip: URL, transcript: String, origin: VoiceTake.Origin) throws -> VoiceTake {
        throw VoiceEditorUnsupported("add a take")
    }
    public func deleteTake(from voice: Voice, id: Int) throws { throw VoiceEditorUnsupported("delete a take") }
    public func updateTake(of voice: Voice, id: Int, transcript: String) throws {
        throw VoiceEditorUnsupported("edit a take")
    }
    public func rebuildMaster(of voice: Voice) throws { throw VoiceEditorUnsupported("rebuild a master") }

    public func window(of slug: String) -> ReferenceWindowMeta? { nil }
    public func setWindow(of voice: Voice, samples: [Float], text: String,
                          derivedFrom: ReferenceWindowMeta.DerivedFrom) throws {
        throw VoiceEditorUnsupported("set a reference window")
    }
    public func clearWindow(of voice: Voice) throws { throw VoiceEditorUnsupported("clear a reference window") }

    @discardableResult
    public func addVariant(of voice: Voice, key: String, clip: URL, transcript: String) throws -> String {
        throw VoiceEditorUnsupported("add an emotion version")
    }
    public func deleteVariant(of voice: Voice, key: String) {}

    public func packExport(for voice: Voice, includeSource: Bool) -> (@Sendable () throws -> Data)? { nil }
}
