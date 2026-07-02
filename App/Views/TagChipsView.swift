import SwiftUI

/// Click-to-insert delivery tags, mirroring the web studio's bench chips.
/// Fish's documented tag vocabulary, grouped; the model also accepts
/// free-form bracketed phrases — hence the custom field. Tags insert at the
/// caret (via `CaretTextEditor`'s live selection), replacing any selected text.
struct TagChipsView: View {
    @Binding var text: String
    @Binding var selection: NSRange
    @AppStorage("tagChipsExpanded") private var expanded = true
    @State private var customTag = ""

    private static let groups: [(label: String, color: Color, tags: [String])] = [
        ("emotion", Brand.peak,
         ["excited", "excited tone", "delight", "surprised", "shocked",
          "angry", "sad"]),
        ("voice & volume", Brand.accent,
         ["whisper", "low voice", "low volume", "loud", "volume up",
          "volume down", "shouting", "screaming", "echo", "with strong accent"]),
        ("sounds", .orange,
         ["laughing", "laughing tone", "chuckle", "chuckling", "sigh",
          "inhale", "exhale", "panting", "moaning", "clearing throat", "tsk",
          "audience laughter", "singing"]),
        ("pacing", .green,
         ["pause", "short pause", "emphasis", "interrupting"]),
    ]

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            // The bench itself scrolls (StudioView wraps it in a ScrollView),
            // so the chips lay out at full height — no inner scroll region.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.label.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Brand.fgFaint)
                        FlowLayout(spacing: 6) {
                            ForEach(group.tags, id: \.self) { tag in
                                chip(tag, color: group.color)
                            }
                        }
                    }
                }
                HStack(spacing: 6) {
                    TextField("custom — free-form works, e.g. whisper in small voice",
                              text: $customTag)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onSubmit { insertCustom() }
                    Button("+ Tag") { insertCustom() }
                        .disabled(customTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Label("Inject tags — click to insert", systemImage: "tag")
        }
        .font(.callout)
    }

    private func chip(_ tag: String, color: Color) -> some View {
        Button("[\(tag)]") { insert(tag) }
            .buttonStyle(.plain)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
            .foregroundStyle(color)
            .accessibilityIdentifier("tag-chip-\(tag)")
            .help("Insert [\(tag)] at the cursor")
    }

    private func insertCustom() {
        var raw = customTag.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasPrefix("[") { raw.removeFirst() }
        while raw.hasSuffix("]") { raw.removeLast() }
        guard !raw.isEmpty else { return }
        insert(raw)
        customTag = ""
    }

    private func insert(_ tag: String) {
        let chip = "[\(tag)]"
        let ns = text as NSString
        let loc = max(0, min(selection.location, ns.length))
        let len = max(0, min(selection.length, ns.length - loc))
        let range = NSRange(location: loc, length: len)

        let precededByWhitespace = loc == 0
            || ns.substring(with: NSRange(location: loc - 1, length: 1)) == " "
            || ns.substring(with: NSRange(location: loc - 1, length: 1)) == "\n"
        let insertion = (precededByWhitespace ? "" : " ") + chip + " "

        text = ns.replacingCharacters(in: range, with: insertion)
        selection = NSRange(location: loc + (insertion as NSString).length, length: 0)
    }
}

/// Minimal wrapping layout for the chip rows (no built-in flow on macOS 14).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        // Never echo an infinite/nil proposal back as our size — returning
        // .infinity blanks the entire view subtree.
        let proposedWidth: CGFloat? = proposal.width.flatMap {
            $0.isFinite ? $0 : nil
        }
        let rows = layout(subviews: subviews, width: proposedWidth ?? .infinity)
        let width = proposedWidth ?? rows.map(\.width).max() ?? 0
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, width: bounds.width)
        var index = 0
        for row in rows {
            var x = bounds.minX
            for size in row.sizes {
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
        }
    }

    private struct Row {
        var sizes: [CGSize] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var y: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !current.sizes.isEmpty, current.width + spacing + size.width > width {
                current.y = y
                rows.append(current)
                y += current.height + spacing
                current = Row()
            }
            current.width += current.sizes.isEmpty ? size.width
                                                   : spacing + size.width
            current.sizes.append(size)
            current.height = max(current.height, size.height)
        }
        if !current.sizes.isEmpty {
            current.y = y
            rows.append(current)
        }
        return rows
    }
}
