import AppKit
import Foundation

/// Presents macOS's standard share menu for a file — AirDrop, Messages, Mail,
/// and whatever else the user has enabled — anchored to the key window.
///
/// AppKit rather than SwiftUI's `ShareLink` because `ShareLink` wants its URL
/// at view-build time: putting one in a row's menu would export a pack every
/// time any menu rendered, whether or not the user shared anything. Here the
/// export happens on the click.
enum SharePicker {
    /// Write `data` somewhere the share services can read it, under a filename
    /// the recipient will see.
    ///
    /// Each call gets its own temp subdirectory so two shares of different
    /// voices can't collide, and so the filename itself stays exactly
    /// `<slug>.gvoice` — AirDrop shows the recipient this name, and a
    /// deduplicating suffix in it would look like part of the voice.
    static func stage(_ data: Data, filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try data.write(to: url)
        return url
    }

    /// Show the picker. No-op without a key window — there is nothing to anchor
    /// to, and an unanchored picker would appear detached from the click.
    @MainActor
    static func present(_ url: URL) {
        guard let window = NSApp.keyWindow, let anchor = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        // Anchored to the window's leading edge at the sidebar's width, which
        // is where the row that triggered this lives. A menu item can't report
        // its own screen rect, so this is the closest honest anchor.
        let rect = NSRect(x: anchor.bounds.minX + 120, y: anchor.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
    }
}
