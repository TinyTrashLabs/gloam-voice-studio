import Foundation

/// Processing stages reported during vocal separation.
///
/// Stages progress in order from ``loading`` through ``writing``.
/// Each stage represents a distinct phase of the htdemucs v4 pipeline.
public enum DemucsStage: String, Sendable, CaseIterable {
    /// Loading model weights from disk into GPU memory.
    case loading

    /// Computing the Short-Time Fourier Transform on the input waveform.
    case stft

    /// Running the spectral (Conv2d) and temporal (Conv1d) encoder branches.
    case encoding

    /// Running the 5-layer cross-domain transformer that fuses both branches.
    case transformer

    /// Running the spectral and temporal decoders, then iSTFT reconstruction.
    case decoding

    /// Writing separated audio (vocals + accompaniment) to WAV files.
    case writing
}
