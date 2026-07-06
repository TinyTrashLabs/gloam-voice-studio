import AudioToolbox
import CoreAudio
import Foundation
import StudioKit

/// Records what the Mac is playing (system audio output) via a Core Audio
/// process tap + private aggregate device — the "capture from another app to
/// clone a voice" path. Gloam's own audio process is excluded from the tap so
/// previews and chat speech can never leak into the clip.
///
/// Requires macOS 14.2+ and the System Audio Recording permission (the OS
/// prompts on first use; NSAudioCaptureUsageDescription supplies the copy).
@available(macOS 14.2, *)
final class SystemAudioRecorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case osStatus(String, OSStatus)
        case noAudio

        var errorDescription: String? {
            switch self {
            case .osStatus(let stage, let status):
                return "System audio capture failed (\(stage), \(status)). "
                    + "Check System Settings → Privacy & Security → Screen & System Audio Recording."
            case .noAudio:
                return "No audio was captured — play the source audio while recording."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var channels = 2
    private(set) var sampleRate = 44_100.0

    /// Starts tapping system output. Throws with a permission hint on failure.
    func start() throws {
        // Exclude our own process from the tap.
        let selfObject = try translatePIDToProcessObject(ProcessInfo.processInfo.processIdentifier)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [selfObject])
        description.isPrivate = true
        // muteBehavior defaults to unmuted — the user keeps hearing the source.

        var newTap = AudioObjectID(kAudioObjectUnknown)
        try check("create tap", AudioHardwareCreateProcessTap(description, &newTap))
        tapID = newTap

        // Tap stream format (float32; usually stereo at the device rate).
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check("read tap format",
                  AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd))
        sampleRate = asbd.mSampleRate
        channels = max(1, Int(asbd.mChannelsPerFrame))

        // Private aggregate device that hosts the tap; auto-starts it.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Gloam System Audio Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        try check("create aggregate device",
                  AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate))
        aggregateID = newAggregate

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregateID, DispatchQueue(label: "fm.gloam.system-tap")
        ) { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData))
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let floats = data.bindMemory(to: Float.self, capacity: count)
                let perBufferChannels = max(1, Int(buffer.mNumberChannels))
                self.lock.lock()
                if perBufferChannels == 1 {
                    self.samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
                } else {
                    // Interleaved: average channels down to mono.
                    var i = 0
                    while i + perBufferChannels <= count {
                        var sum: Float = 0
                        for c in 0..<perBufferChannels { sum += floats[i + c] }
                        self.samples.append(sum / Float(perBufferChannels))
                        i += perBufferChannels
                    }
                }
                self.lock.unlock()
            }
        }
        try check("install io proc", status)
        ioProcID = procID
        try check("start device", AudioDeviceStart(aggregateID, procID))
    }

    /// Stops the tap and returns the capture as a 16-bit mono WAV.
    func stopAndEncodeWAV() throws -> Data {
        teardown()
        lock.lock()
        let captured = samples
        samples = []
        lock.unlock()
        guard captured.contains(where: { abs($0) > 0.0005 }) else {
            throw RecorderError.noAudio
        }
        return WAVEncoder.encode(pcm16: PCM16.data(from: captured),
                                 sampleRate: Int(sampleRate))
    }

    func cancel() { teardown() }

    deinit { teardown() }

    private func teardown() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func translatePIDToProcessObject(_ pid: Int32) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check("translate pid", AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<Int32>.size), &pidValue, &size, &object))
        return object
    }

    private func check(_ stage: String, _ status: OSStatus) throws {
        guard status == noErr else { throw RecorderError.osStatus(stage, status) }
    }
}
