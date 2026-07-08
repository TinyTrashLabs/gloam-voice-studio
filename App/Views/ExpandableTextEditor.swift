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
            .accessibilityIdentifier("\(accessibilityID)-resize-handle")
    }
}
