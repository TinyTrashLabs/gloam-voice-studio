import SwiftUI
import StudioKit

/// The paid apps this engine powers, as a list of rows.
///
/// One view for all three placements so the copy and the link-building can't
/// drift between them; the campaign token is what distinguishes a click here
/// from a click in the server pane.
struct SiblingAppsList: View {
    let campaign: SiblingAppCampaign

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SiblingApps.all) { app in
                Link(destination: SiblingApps.link(app, campaign: campaign)) {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: app.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Brand.accent)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(app.name).font(.callout.weight(.medium))
                                    .foregroundStyle(Brand.fg)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 8)).foregroundStyle(Brand.fgFaint)
                            }
                            Text(app.tagline)
                                .font(.caption).foregroundStyle(Brand.fgDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sibling-app-\(app.id)")
            }
        }
    }
}

/// Single-line variant for spots where a full list would crowd the work area.
struct SiblingAppsFootnote: View {
    let campaign: SiblingAppCampaign

    var body: some View {
        HStack(spacing: 4) {
            Text("This engine also powers").foregroundStyle(Brand.fgFaint)
            ForEach(Array(SiblingApps.all.enumerated()), id: \.element.id) { index, app in
                if index > 0 { Text("and").foregroundStyle(Brand.fgFaint) }
                Link(app.name, destination: SiblingApps.link(app, campaign: campaign))
                    .foregroundStyle(Brand.accent)
                    .accessibilityIdentifier("sibling-app-\(app.id)")
            }
        }
        .font(.caption)
    }
}
