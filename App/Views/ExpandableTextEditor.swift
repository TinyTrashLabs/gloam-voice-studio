import AppKit
import StudioKit
import SwiftUI

/// A `TextEditor` that auto-grows with content (up to `maxHeight`) and can
/// also be dragged taller/shorter via a handle at the bottom edge. Height
/// math lives in `StudioKit.ExpandableTextHeight` (unit-tested there); this
/// view is just the SwiftUI wiring around it.
struct ExpandableTextEditor: View {
    @Binding var text: String
    var minHeight: Double = 44
    var maxHeight: Double = 220
    var dragCeiling: Double = 600
    var accessibilityID: String
    /// When set, file drags land here instead of in the text. Needed because
    /// `TextEditor`'s backing `NSTextView` accepts file drops on its own and
    /// inserts the path as text — a plain SwiftUI `.onDrop` on this view does
    /// NOT suppress that native behavior, it just runs alongside it (both
    /// fire for the same drop). `FileDropCatcher` sits in front as a real
    /// `NSDraggingDestination` so the native text view never sees the drag.
    var onFileDrop: (([URL]) -> Void)? = nil

    @State private var manualHeight: Double?
    @State private var dragBaseHeight: Double?

    private var autoHeight: Double {
        let lines = text.isEmpty ? 1 : text.components(separatedBy: "\n").count
        return ExpandableTextHeight.forLineCount(lines, min: minHeight, max: maxHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .frame(height: manualHeight ?? autoHeight)
                .accessibilityIdentifier(accessibilityID)
                .overlay { if let onFileDrop { FileDropCatcher(onDrop: onFileDrop) } }
            resizeHandle
        }
    }

    private var resizeHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 9))
            .foregroundStyle(Brand.fgFaint)
            .frame(maxWidth: .infinity, minHeight: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragBaseHeight ?? (manualHeight ?? autoHeight)
                        dragBaseHeight = base
                        manualHeight = ExpandableTextHeight.dragged(
                            base: base, delta: value.translation.height,
                            min: minHeight, max: dragCeiling)
                    }
                    .onEnded { _ in dragBaseHeight = nil }
            )
            .help("Drag to resize")
            .accessibilityLabel("Resize text box")
            .accessibilityIdentifier("\(accessibilityID)-resize-handle")
    }
}

/// A transparent, top-most `NSDraggingDestination` that claims file-URL
/// drags before AppKit can route them to the `NSTextView` underneath.
/// Non-file drags (plain text, etc.) aren't registered for, so they fall
/// through to the text view's normal handling.
private struct FileDropCatcher: NSViewRepresentable {
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onDrop = onDrop
        view.registerForDraggedTypes([.fileURL])
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onDrop = onDrop
    }

    final class CatcherView: NSView {
        var onDrop: (([URL]) -> Void)?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
                ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty
            else { return false }
            onDrop?(urls)
            return true
        }
    }
}
