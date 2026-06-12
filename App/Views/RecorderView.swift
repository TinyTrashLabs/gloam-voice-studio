import AVFAudio
import StudioKit
import SwiftUI

struct RecorderView: View {
    let onFinish: (Data, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var recorder: AVAudioRecorder?
    @State private var fileURL: URL?
    @State private var startedAt: Date?
    @State private var error: String?
    @State private var tick = Date()
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            Text("Record Reference").font(.title3.bold())
            Text("Read a few natural sentences — 5 to 20 seconds works well.")
                .font(.callout).foregroundStyle(.secondary)
            if let startedAt {
                Text(String(format: "%.0f s", tick.timeIntervalSince(startedAt)))
                    .font(.system(.title, design: .monospaced))
                    .onReceive(timer) { tick = $0 }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { recorder?.stop(); dismiss() }
                if recorder == nil {
                    Button("Start Recording") { start() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Stop & Use") { stopAndUse() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func start() {
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

    private func stopAndUse() {
        recorder?.stop()
        recorder = nil
        guard let fileURL else { return }
        do {
            let seconds = try RefAudioValidator.validate(url: fileURL)
            onFinish(try Data(contentsOf: fileURL), seconds)
            try? FileManager.default.removeItem(at: fileURL)
            dismiss()
        } catch { self.error = "\(error)" }
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
