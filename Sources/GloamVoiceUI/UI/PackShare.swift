import SwiftUI
#if os(iOS)
import LinkPresentation
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Sharing a voice as a `.gvoice`, with the wait made visible.
///
/// `ShareLink` with a file representation zips the pack inside the share
/// sheet's own item request, on the main thread: nothing on screen moves
/// until the zip is written AND the system sheet has come up, which on a
/// phone reads as a dead button. This does the work off the main thread the
/// moment Share is tapped, shows "Packing…" while it runs, then presents the
/// sheet with a finished file.
@MainActor
public final class PackShare: ObservableObject {
    struct Ready: Identifiable {
        let id = UUID()
        let url: URL
        let voice: Voice
    }

    @Published private(set) var packing: Voice?
    @Published var ready: Ready?
    @Published var errorText: String?

    public init() {}

    public func share(_ voice: Voice, includeSource: Bool, using store: any VoiceLibraryStore) {
        guard packing == nil else { return }
        let export = VoicePackExport(voice: voice, includeSource: includeSource, store: store)
        packing = voice
        Task {
            defer { packing = nil }
            do {
                ready = Ready(url: try await export.writeInBackground(), voice: voice)
            } catch {
                errorText = userMessage(for: error)
            }
        }
    }
}

extension View {
    /// The three pieces of share UI a screen needs: the packing pill, the
    /// share sheet once the file exists, and the alert when it can't.
    public func packShareUI(_ share: PackShare) -> some View { modifier(PackShareUI(share: share)) }
}

private struct PackShareUI: ViewModifier {
    @ObservedObject var share: PackShare

    func body(content: Content) -> some View {
        content
            .overlay {
                if let voice = share.packing {
                    PackingPill(voice: voice)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: share.packing)
            .sheet(item: $share.ready) { ready in
                #if os(iOS)
                ActivitySheet(items: [PackActivityItem(url: ready.url, voice: ready.voice)])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
                #else
                MacShareSheet(ready: ready)
                #endif
            }
            .alert("Couldn't share", isPresented: .init(get: { share.errorText != nil },
                                                        set: { if !$0 { share.errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(share.errorText ?? "") }
    }
}

/// The wait, in the console's own idiom: spinner and a monospace line.
private struct PackingPill: View {
    let voice: Voice
    @Environment(\.voiceEditorTheme) private var t

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().tint(t.accent)
            Text("PACKING \(voice.name.uppercased())…")
                .font(t.console(11, .medium)).tracking(1)
                .foregroundStyle(t.fg)
                .lineLimit(1)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Capsule().fill(t.ink2))
        .overlay(Capsule().strokeBorder(t.panelStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .accessibilityLabel("Packing \(voice.name)")
    }
}

#if os(iOS)
/// The system share sheet, handed a file that already exists.
private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_: UIActivityViewController, context: Context) {}
}

/// What the sheet shows for the pack: the voice's name and its avatar, not
/// a generic document glyph and a slug.
private final class PackActivityItem: NSObject, UIActivityItemSource {
    let url: URL
    let voice: Voice
    init(url: URL, voice: Voice) { self.url = url; self.voice = voice }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any { url }
    func activityViewController(_: UIActivityViewController,
                                itemForActivityType _: UIActivity.ActivityType?) -> Any? { url }
    func activityViewController(_: UIActivityViewController,
                                subjectForActivityType _: UIActivity.ActivityType?) -> String {
        "\(voice.name) — Gloam voice"
    }
    func activityViewControllerLinkMetadata(_: UIActivityViewController) -> LPLinkMetadata? {
        let meta = LPLinkMetadata()
        meta.title = voice.name
        meta.originalURL = url
        if let image = VoiceAvatarView.image(for: voice) {
            meta.iconProvider = NSItemProvider(object: image)
        }
        return meta
    }
}
#else
/// macOS: the finished pack, with the system share menu and a way to find it.
/// (iOS presents the full activity sheet; a Mac has `ShareLink` and Finder.)
private struct MacShareSheet: View {
    let ready: PackShare.Ready
    @Environment(\.dismiss) private var dismiss
    @Environment(\.voiceEditorTheme) private var t

    var body: some View {
        VStack(spacing: 16) {
            Text(ready.voice.name).font(t.masthead(18)).foregroundStyle(t.fg)
            Text("Gloam voice pack · \(ready.url.lastPathComponent)")
                .font(t.console(11)).foregroundStyle(t.fgFaint)
            HStack(spacing: 12) {
                ShareLink(item: ready.url, subject: Text("\(ready.voice.name) — Gloam voice")) {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ready.url])
                }
            }
            .tint(t.accent)
            Button("Done") { dismiss() }
                .font(t.console(12)).foregroundStyle(t.fgDim)
        }
        .padding(28)
        .frame(minWidth: 340)
        .background(t.ground)
        .preferredColorScheme(.dark)
    }
}
#endif
