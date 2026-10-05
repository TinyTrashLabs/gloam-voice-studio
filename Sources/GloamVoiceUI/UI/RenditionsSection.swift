import SwiftUI

/// What the pack carries per engine, read-only: baking happens on the
/// desktop, but a pack from the Mac is inspectable here. Also the pace
/// overrides other engines carry, which the phone shows and does not touch
/// (the Delivery slider is the voice's `pace`, and writes the `lux-tts`
/// override away).
public struct RenditionsSection: View {
    let voice: Voice
    @EnvironmentObject private var host: VoiceEditorHost
    @Environment(\.voiceEditorTheme) private var t

    public init(voice: Voice) { self.voice = voice }

    /// The rows and labels are `Renditions`' (GloamVoiceEditing); these
    /// forward so existing callers keep compiling.
    public static func rows(engines: [String: [String: URL]]) -> [(engine: String, files: [(name: String, bytes: Int)])] {
        Renditions.rows(engines: engines)
    }
    public static func paceOverrides(_ enginePace: [String: Double]?) -> [(engine: String, pace: Double)] {
        Renditions.paceOverrides(enginePace)
    }
    public static func sizeLabel(_ bytes: Int) -> String { Renditions.sizeLabel(bytes) }

    public var body: some View {
        let engines = host.store.engineFiles(of: voice.slug)
        let rows = Self.rows(engines: engines)
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.engine) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.engine).font(t.console(12, .semibold)).foregroundStyle(t.accent)
                        ForEach(row.files, id: \.name) { file in
                            LabeledContent {
                                Text(Self.sizeLabel(file.bytes)).font(t.console(11)).foregroundStyle(t.fgFaint)
                            } label: {
                                Text(file.name).font(t.console(11)).foregroundStyle(t.fg)
                            }
                        }
                    }
                }
            } header: {
                Text("Renditions").font(t.console(11, .medium)).tracking(1.5).foregroundStyle(t.fgFaint)
            } footer: {
                Text("Per-engine files the pack carries. Baked on the desktop; the phone reads them and keeps them when the pack is shared on.")
                    .font(t.sans(11)).foregroundStyle(t.fgFaint)
            }
            .listRowBackground(t.panel)
        }
    }
}
