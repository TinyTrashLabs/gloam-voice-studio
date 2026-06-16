import AppKit
import SwiftUI

/// Plain-text editor backed by NSTextView so we can track the caret/selection
/// and insert text (e.g. Fish `[tags]`) AT THE CURSOR instead of only appending.
/// `selection` always reflects the live caret/selection; writing to `text`
/// externally (tag insert, preset, reset) restores the caret from `selection`.
struct CaretTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        // Only push text in when it changed externally (not the user's own
        // keystrokes — those already match), then restore the caret from
        // `selection` so an inserted tag lands where it should.
        if tv.string != text {
            tv.string = text
            let len = (text as NSString).length
            let loc = max(0, min(selection.location, len))
            let length = max(0, min(selection.length, len - loc))
            tv.setSelectedRange(NSRange(location: loc, length: length))
            tv.scrollRangeToVisible(NSRange(location: loc, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CaretTextEditor
        init(_ parent: CaretTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.selection = tv.selectedRange()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.selection = tv.selectedRange()
        }
    }
}
