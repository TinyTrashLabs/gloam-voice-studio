import AVFAudio
import StudioKit
import SwiftUI

struct RecorderView: View {
    let onFinish: (Data, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: CaptureSource = .microphone
    @State private var recorder: AVAudioRecorder?
    // SystemAudioRecorder is macOS 14.2+; stored type-erased because stored
    // properties can't carry @available.
    @State private var systemRecorder: AnyObject?
    @State private var fileURL: URL?
    @State private var startedAt: Date?
    @State private var error: String?
    @State private var tick = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    enum CaptureSource: String, CaseIterable {
        case microphone = "Microphone"
        case system = "System Audio"
    }

    private var isRecording: Bool { startedAt != nil }

    var body: some View {
        VStack(spacing: 14) {
            Text("Record Reference").font(.title3.bold())
            if #available(macOS 14.2, *) {
                Picker("Source", selection: $source) {
                    ForEach(CaptureSource.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isRecording)
                .accessibilityIdentifier("record-source")
            }
            Text(source == .microphone
                 ? "Read a few natural sentences — 5 to 20 seconds works well."
                 : "Play the voice you want to clone (any app) — Gloam records what "
                   + "your Mac is playing. 5 to 20 seconds works well.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let startedAt {
                Text(String(format: "%.0f s", tick.timeIntervalSince(startedAt)))
                    .font(.system(.title, design: .monospaced))
                    .onReceive(timer) { tick = $0 }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { cancel() }
                if !isRecording {
                    Button("Start Recording") { start() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Stop & Use") { stopAndUse() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func cancel() {
        recorder?.stop()
        if #available(macOS 14.2, *) {
            (systemRecorder as? SystemAudioRecorder)?.cancel()
        }
        dismiss()
    }

    private func start() {
        error = nil
        switch source {
        case .microphone: startMic()
        case .system: startSystem()
        }
    }

    private func startMic() {
        AVCaptureDeviceRequestBridge.requestMicAccess { granted in
            guard granted else { error = "Microphone access was denied."; return }
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gloam-rec-\(UUID().uuidString).wav")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
                let rec = try AVAudioRecorder(url: url, settings: settings)
                rec.record()
                recorder = rec
                fileURL = url
                startedAt = Date()
                tick = Date()
            } catch { self.error = "\(error)" }
        }
    }

    private func startSystem() {
        guard #available(macOS 14.2, *) else {
            error = "System audio capture needs macOS 14.2 or newer."
            return
        }
        let rec = SystemAudioRecorder()
        do {
            try rec.start()
            systemRecorder = rec
            startedAt = Date()
            tick = Date()
        } catch { self.error = "\(error.localizedDescription)" }
    }

    private func stopAndUse() {
        switch source {
        case .microphone:
            recorder?.stop()
            recorder = nil
            guard let fileURL else { return }
            finish(with: fileURL)
        case .system:
            guard #available(macOS 14.2, *),
                  let rec = systemRecorder as? SystemAudioRecorder else { return }
            systemRecorder = nil
            do {
                let wav = try rec.stopAndEncodeWAV()
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("gloam-sysrec-\(UUID().uuidString).wav")
                try wav.write(to: url)
                finish(with: url)
            } catch {
                startedAt = nil
                self.error = "\(error.localizedDescription)"
            }
        }
    }

    private func finish(with url: URL) {
        do {
            let seconds = try RefAudioValidator.validate(url: url)
            onFinish(try Data(contentsOf: url), seconds)
            try? FileManager.default.removeItem(at: url)
            dismiss()
        } catch {
            startedAt = nil
            self.error = "\(error)"
        }
    }
}

/// AVCaptureDevice lives in AVFoundation; tiny bridge keeps imports local.
import AVFoundation
enum AVCaptureDeviceRequestBridge {
    static func requestMicAccess(_ completion: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in completion(granted) }
        }
    }
}
