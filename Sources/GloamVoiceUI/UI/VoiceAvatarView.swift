import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A voice's face: the pack's avatar when it has one, else the two-letter
/// monogram every list drew before avatars existed. One view for the Voices
/// rows, the Compose rail, the picker and the detail screen, so a picture
/// set in one place shows up everywhere at once.
public struct VoiceAvatarView: View {
    let voice: Voice?
    var size: CGFloat = 46
    var accent: Bool = true
    @Environment(\.voiceEditorTheme) private var t

    public init(voice: Voice?, size: CGFloat = 46, accent: Bool = true) {
        self.voice = voice; self.size = size; self.accent = accent
    }

    public var body: some View {
        if let voice, let image = Self.image(for: voice) {
            Image(platformImage: image)
                .resizable().interpolation(.high).scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(t.accent.opacity(0.4), lineWidth: 1))
                // Same path after a re-shoot: the stamp is what forces a reload.
                .id(voice.avatarModified)
                .accessibilityLabel(voice.name)
        } else {
            Text(voice?.tag ?? "—")
                .font(t.console(size * 0.24, .semibold)).tracking(1)
                .foregroundStyle(accent ? t.accent : t.fgDim)
                .frame(width: size, height: size)
                .background(Circle().fill(accent ? t.accent.opacity(0.14) : t.panel))
                .overlay(Circle().strokeBorder(
                    accent ? t.accent.opacity(0.4) : t.panelStroke, lineWidth: 1))
        }
    }

    static func image(for voice: Voice) -> PlatformImage? {
        guard let url = voice.avatarURL else { return nil }
        #if os(iOS)
        return UIImage(contentsOfFile: url.path)
        #else
        return NSImage(contentsOf: url)
        #endif
    }
}

#if os(iOS)
/// The camera, for a voice's avatar. `UIImagePickerController` rather than
/// AVFoundation: one shot, system UI, nothing to get wrong. Only offered
/// when a camera exists (never on the Simulator). iOS only: a Mac has no
/// such sheet, and the editor hides "Take Photo" there.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    /// Front for a face, rear for a menu on the table.
    var device: UIImagePickerController.CameraDevice = .front
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = device
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // JPEG keeps the EXIF orientation the camera reports; AvatarImage
            // applies it when it makes the square.
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.95) {
                parent.onImage(data)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif
