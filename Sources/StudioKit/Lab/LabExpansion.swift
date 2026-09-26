import Foundation

/// Which Lab comparison groups are open. Everything starts collapsed (a Lab
/// with a dozen comparisons is a wall of players otherwise, David 2026-09-18),
/// so this tracks the EXPANDED set rather than the collapsed one: an unknown
/// group — one that just arrived over MCP, or on launch — is closed.
public struct LabExpansion: Equatable, Sendable {
    public private(set) var expanded: Set<String> = []

    public init(expanded: Set<String> = []) { self.expanded = expanded }

    public func isCollapsed(_ id: String) -> Bool { !expanded.contains(id) }

    public mutating func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    public mutating func expand(_ id: String) { expanded.insert(id) }

    public mutating func collapseAll() { expanded.removeAll() }

    public mutating func expandAll(_ ids: some Sequence<String>) { expanded.formUnion(ids) }
}
