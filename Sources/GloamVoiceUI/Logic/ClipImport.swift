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
    /// Refused before the file is opened. A 100 MB file is over an hour of
    /// MP3 or ten minutes of CD-quality WAV — nothing a 15 s reference needs.
    public static let maxFileBytes = 100 * 1024 * 1024
    /// Only this much of a file is decoded, from the top. Leading room tone is
    /// trimmed after, so a clip whose speech starts within the first two
    /// minutes still windows correctly; anything later is not a clone
    /// reference, it is an episode.
    public static let maxDecodeSeconds = 120.0
    /// LuxTTS refuses references over 30 s (`LuxOnnx.maxReferenceSeconds`, in the app) and
    /// gets expensive well before that: its cost is set by the PROMPT, which
    /// every chunk re-pays. 15 s is the window aidj settled on after measuring
    /// 28.5 s → 14.6 s take a render from 3.68 GB to 1.96 GB — and 3.68 GB is
    /// over the device's kill line.
    public static let luxWindowSeconds = 15.0

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
                return String(format: "That file is %d MB — pick a shorter clip. A clone only uses the first %.0f seconds of speech.",
                              bytes / (1024 * 1024), luxWindowSeconds)
            }
        }
    }

    public struct Imported {
        public let url: URL
        public let seconds: Double
        /// True when the file was longer than the engine's window and was cut.
        public let trimmed: Bool
        /// The prepared audio, 24 kHz mono — what the transcript screen plays
        /// back so the words can be checked against what is actually there.
        public let samples: [Float]
        /// Level, noise, clipping — the same measurement a recording gets.
        public let quality: RecordingCheck.Quality

        public init(url: URL, seconds: Double, trimmed: Bool, samples: [Float], quality: RecordingCheck.Quality) {
            self.url = url; self.seconds = seconds; self.trimmed = trimmed
            self.samples = samples; self.quality = quality
        }
    }

    /// Decode, downmix, resample, length-check, and write a clean 24 kHz mono
    /// WAV into the app's temp directory, windowed to LuxTTS's reference limit.
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

        var seconds = Double(samples.count) / Double(sampleRate)
        guard seconds >= minSeconds else { throw ImportError.tooShort(seconds) }

        let cap = luxWindowSeconds
        var trimmed = false
        if seconds > cap {
            samples = window(samples, maxSeconds: cap)
            seconds = Double(samples.count) / Double(sampleRate)
            trimmed = true
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString).wav")
        try VoicePlayer.wavData(samples: samples, sampleRate: sampleRate).write(to: url)
        return Imported(url: url, seconds: seconds, trimmed: trimmed, samples: samples,
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
                        trimmed: false, samples: cleaned, quality: quality)
    }

    /// Cut to `maxSeconds`, ending at the quietest point in the last stretch so
    /// the reference does not stop mid-word — a clipped final syllable is a
    /// pronunciation the prompt then teaches the model.
    public static func window(_ samples: [Float], maxSeconds: Double) -> [Float] {
        let limit = Int(maxSeconds * Double(sampleRate))
        guard samples.count > limit else { return samples }
        let frame = sampleRate / 100                    // 10 ms
        let searchFrom = max(0, limit - sampleRate * 2) // look back up to 2 s
        var bestCut = limit
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = searchFrom
        while i + frame <= limit {
            var sum: Float = 0
            for s in samples[i..<(i + frame)] { sum += s * s }
            if sum < bestEnergy { bestEnergy = sum; bestCut = i + frame }
            i += frame
        }
        return Array(samples[0..<bestCut])
    }
}
