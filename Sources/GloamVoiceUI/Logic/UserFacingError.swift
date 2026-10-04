import Foundation
import GVoiceKit

/// Errors a `VoiceLibraryStore` throws itself, distinct from `GVoiceKit.StudioError`.
public enum VoiceStoreError: Error, Equatable {
    /// The file handed to `importPack(from:)` is bigger than the host store's pack size limit.
    case packTooLarge
    /// `library.save`/`GVoice.import` reported success but the slug it
    /// returned isn't in the reloaded list — should never happen, but this
    /// keeps the add/import path free of force-unwraps.
    case notFoundAfterSave(String)
    /// `setAvatar` was handed bytes ImageIO cannot decode.
    case unreadableImage
    /// `updateTranscript` was handed nothing but whitespace.
    case emptyTranscript
    /// `rebuildMaster` was asked to build from no takes.
    case noTakes
    /// `clearWindow` on a master past the engine's cap: without a window
    /// the voice could not render.
    case masterTooLongForNoWindow
}

/// Turns an error from the import/save path into one plain sentence for an
/// alert. `StudioError` (GVoiceKit) is a plain enum, not `LocalizedError`, so
/// its cases would otherwise surface as Swift's default `"invalidArchive(\"…\")"`
/// dump — readable to us, not to the person tapping "Import".
public func userMessage(for error: Error) -> String {
    if let studio = error as? StudioError {
        switch studio {
        case .invalidArchive(let detail):
            // GVoiceKit throws `.invalidArchive` both for "not a zip/not a
            // pack at all" and for "a valid pack with nothing installable in
            // it" (no base variant, no reference audio, no engine assets).
            // Those read very differently to a user, so split on the detail.
            if detail.localizedCaseInsensitiveContains("nothing to install")
                || detail.localizedCaseInsensitiveContains("no base variant") {
                return "This pack has nothing to install."
            }
            return "This file isn't a voice pack."
        case .voiceExists:
            return "A voice with that name already exists."
        case .invalidName:
            return "That name can't be used for a voice."
        case .invalidRefAudio:
            return "The reference recording couldn't be read."
        case .voiceNotFound:
            return "That voice couldn't be found."
        case .historyEntryNotFound:
            return "That take couldn't be found."
        }
    }
    if let store = error as? VoiceStoreError {
        switch store {
        case .packTooLarge:
            return "This voice pack is too large to import (limit 64 MB)."
        case .notFoundAfterSave:
            return "That voice couldn't be saved."
        case .unreadableImage:
            return "That picture couldn't be read."
        case .emptyTranscript:
            return "The reference needs its words — type what the recording says."
        case .noTakes:
            return "Add a take before building the master."
        case .masterTooLongForNoWindow:
            return String(format: "The master is longer than %.0f seconds, so the voice needs a reference window.", ReferenceWindowRule.maxSeconds)
        }
    }
    return error.localizedDescription
}
