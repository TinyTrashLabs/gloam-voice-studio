import Combine
import SwiftUI

/// The editor's one environment object: a store, what the host can do beside
/// it, and how it should look. Republishes the store's changes, so a view
/// reading `host.store.voices` redraws when they change.
///
///     NavigationStack { … }
///         .voiceEditorHost(host)
///
/// Attach it ABOVE the navigation stack: the editor is pushed and presented,
/// and both inherit it from there.
/// The host's consent screen: call the first closure when the person agrees,
/// the second when they back out.
public typealias ConsentSheet = @MainActor (_ onAccept: @escaping () -> Void, _ onCancel: @escaping () -> Void) -> AnyView

/// A plain consent question for a host that set a `ConsentGate` but no sheet.
struct DefaultConsentSheet: View {
    let deviceNoun: String
    let onAccept: () -> Void
    let onCancel: () -> Void
    @Environment(\.voiceEditorTheme) private var t

    var body: some View {
        VStack(spacing: 18) {
            Text("Is this your voice?").font(t.mastheadItalic(26)).foregroundStyle(t.fg)
            Text("Only add a voice that is yours, or one you have permission to use. It stays on \(deviceNoun).")
                .font(t.sans(15)).foregroundStyle(t.fgDim).multilineTextAlignment(.center)
            Button("It's mine, or I have permission", action: onAccept).buttonStyle(.borderedProminent).tint(t.accent)
            Button("Cancel", role: .cancel, action: onCancel).tint(t.fgDim)
        }
        .padding(28)
        .presentationDetents([.medium])
    }
}

@MainActor
public final class VoiceEditorHost: ObservableObject {
    public let store: any VoiceLibraryStore
    public var capabilities: VoiceEditorCapabilities
    /// How the host asks for `capabilities.consent`: its own sheet, given
    /// what to call when the person agrees or backs out. Nil draws
    /// `DefaultConsentSheet`. Only consulted when the gate says it is required.
    public var consentSheet: ConsentSheet?
    public var theme: VoiceEditorTheme

    private var forward: AnyCancellable?

    public init(store: any VoiceLibraryStore,
                capabilities: VoiceEditorCapabilities = .none,
                consentSheet: ConsentSheet? = nil,
                theme: VoiceEditorTheme = .gloam) {
        self.store = store
        self.capabilities = capabilities
        self.consentSheet = consentSheet
        self.theme = theme
        forward = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public var features: VoiceLibraryFeatures { store.features }

    /// The reference's words, falling back to the voice's own `refText`.
    func referenceText(for voice: Voice) -> String { store.referenceText(for: voice) }

    /// Playback level for `voice`: the app's 0.8 default times its own trim.
    func outputGain(for voice: Voice) -> Float { store.outputGain(for: voice) }

    /// Whether adding audio must first ask the host's consent question.
    var needsConsent: Bool { capabilities.consent?.isRequired() == true }

    /// The consent question, drawn by the host's sheet or the default one.
    /// Agreeing records it through the gate before `onAccept` runs.
    @ViewBuilder
    func consentView(onAccept: @escaping () -> Void, onCancel: @escaping () -> Void) -> some View {
        let accept = { [capabilities] in capabilities.consent?.accept(); onAccept() }
        if let consentSheet {
            consentSheet(accept, onCancel)
        } else {
            DefaultConsentSheet(deviceNoun: capabilities.deviceNoun, onAccept: accept, onCancel: onCancel)
        }
    }
}

extension View {
    /// Gives the editor (and everything it presents) its store, capabilities
    /// and theme.
    public func voiceEditorHost(_ host: VoiceEditorHost) -> some View {
        environmentObject(host).environment(\.voiceEditorTheme, host.theme)
    }
}
