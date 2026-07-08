import Foundation

/// Turns N separately-synthesized chunk sample arrays into one saved-take
/// WAV: concatenate first, THEN fade only the combined buffer's outer
/// edges — not each chunk's edges individually, which would leave small
/// dips at every internal seam and make a multi-sentence reply sound like
/// several stitched clips instead of one continuous take.
public enum ChatAudioAssembly {
    public static func concatenateAndEncode(_ chunks: [[Float]], sampleRate: Int) -> Data {
        let combined = chunks.flatMap { $0 }
        let faded = AudioAssembler.fadeEdges(combined, sampleRate: sampleRate)
        return WAVEncoder.encode(pcm16: PCM16.data(from: faded), sampleRate: sampleRate)
    }
}
