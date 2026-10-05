import AVFoundation
import Foundation

/// Importing an existing recording as a clone reference, instead of reading the
/// script into the mic.
///
/// Recording gives the clone two things for free: audio at a known length, and
/// a transcript (the user read `readLine`, so we already know what was said). A
/// file gives neither, and LuxTTS clones from audio *plus* its transcript — so
/// this module supplies both: it normalizes the audio to what the engines
/// expect, and transcribes the result on-device.
///
/// Ported from aidj's `UserVoiceStore` + `VoiceTranscriber`, which solved the
/// same problem for the radio app's cloning flow.
public enum ClipImport {
    /// Everything is normalized to 24 kHz mono at import: both cloners consume
    /// exactly that, so converting once here means the clone path never has to,
    /// and a file that cannot decode fails AT IMPORT — visibly — rather than
    /// somewhere inside a render.
    public static let sampleRate = 24_000
    /// Same floor as a recording (`RecordingCheck.minSeconds`): an import is
    /// judged by the rules a take is.
    public static let minSeconds = RecordingCheck.minSeconds
    /// Refused before the file is opened: not a clone reference, an archive.
    public static let maxFileBytes = 200 * 1024 * 1024
    /// Memory guard for the decoder, not a reference length: ten minutes of
    /// 24 kHz mono is what is ever read from a file. The whole clip up to that
    /// is kept as the master; each engine picks its own section of it.
    public static let maxDecodeSeconds = 600.0

    public enum ImportError: LocalizedError {
        case unreadable(String)
        case undecodable(String)
        case tooShort(Double)
        case tooLarge(Int)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let n): return "Couldn't open \(n) — try copying it into Files first."
            case .undecodable(let m): return "Couldn't decode that audio: \(m)"
            case .tooShort(let s):
                return String(format: "That clip is %.1fs — a clone needs at least %.0fs of speech.", s, minSeconds)
            case .tooLarge(let bytes):
                return String(format: "That file is %d MB — too large to import as a voice.", bytes / (1024 * 1024))
            }
        }
    }

    public struct Imported {
        public let url: URL
        public let seconds: Double
        /// The prepared audio, 24 kHz mono — what the transcript screen plays
        /// back so the words can be checked against what is actually there.
        public let samples: [Float]
        /// Level, noise, clipping — the same measurement a recording gets.
        public let quality: RecordingCheck.Quality
        /// True when `samples` / the file already went through
        /// `RecordingCleanup` (a recorded take, `prepareTake`) -- the store
        /// must not clean it a second time on save.
        public var cleaned = false

        public init(url: URL, seconds: Double, samples: [Float], quality: RecordingCheck.Quality,
                    cleaned: Bool = false) {
            self.url = url; self.seconds = seconds
            self.samples = samples; self.quality = quality
            self.cleaned = cleaned
        }
    }

    /// Decode, downmix, resample, length-check, and write a clean 24 kHz mono
    /// WAV into the app's temp directory. The whole clip is kept: it is the
    /// voice's master, and each engine picks the section it can use.
    /// (The iPhone's copy cut an import to LuxTTS's 15 s here; deliberately
    /// not ported: sections are the pack's, prepared by the library.)
    public static func prepare(_ src: URL) throws -> Imported {
        // Files handed over by the document picker live outside the sandbox.
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        if let size = try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileBytes {
            throw ImportError.tooLarge(size)
        }
        var samples: [Float]
        do { samples = try VoiceAudio.loadWav24k(src, maxSeconds: maxDecodeSeconds) } catch {
            throw ImportError.undecodable(error.localizedDescription)
        }
        guard !samples.isEmpty else { throw ImportError.unreadable(src.lastPathComponent) }

        // Trim room tone before measuring: a long silent tail should not count
        // against a clip, nor eat the window.
        samples = ClipPrep.trimAndFade(samples)
        samples = ClipPrep.removeDC(samples)

        let seconds = Double(samples.count) / Double(sampleRate)
        guard seconds >= minSeconds else { throw ImportError.tooShort(seconds) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).wav")
        try VoicePlayer.wavData(samples: samples, sampleRate: sampleRate).write(to: url)
        return Imported(url: url, seconds: seconds, samples: samples,
                        quality: RecordingCheck.measure(samples, sampleRate: sampleRate))
    }

    /// A take from the studio's own recorder, made ready for the transcriber
    /// and the engine. The quality verdict is measured on the RAW take -- "too
    /// quiet" and "too noisy" must describe what the mic heard -- but what
    /// travels on is trimmed and levelled to the reference target, because
    /// the on-device recogniser mis-hears a −40 dBFS take and the engine's
    /// render follows the reference's RMS. The durable recording itself is
    /// untouched so an interrupted clone can still be resumed from it.
    public static func prepareTake(_ src: URL) throws -> Imported {
        let raw: [Float]
        do { raw = try VoiceAudio.loadWav24k(src) } catch {
            throw ImportError.undecodable(error.localizedDescription)
        }
        guard !raw.isEmpty else { throw ImportError.unreadable(src.lastPathComponent) }
        let quality = RecordingCheck.measure(raw, sampleRate: sampleRate)
        let cleaned = RecordingCleanup.clean(raw, sampleRate: sampleRate)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("take-\(UUID().uuidString).wav")
        try VoicePlayer.wavData(samples: cleaned, sampleRate: sampleRate).write(to: url)
        return Imported(url: url, seconds: Double(cleaned.count) / Double(sampleRate),
                        samples: cleaned, quality: quality, cleaned: true)
    }
}
