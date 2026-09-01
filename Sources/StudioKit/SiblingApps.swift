import Foundation

/// One of the paid apps this engine powers.
public struct SiblingApp: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let tagline: String
    /// SF Symbol shown beside the row.
    public let symbol: String
    /// Apple's numeric App Store id.
    ///
    /// Nil until the app actually ships. A nil id is not an error state — the
    /// link falls back to the marketing site, which exists today, rather than
    /// shipping a `?id=` URL that lands on an App Store error page. Filling this
    /// in is the entire go-live change.
    public let appStoreID: String?
    public let webURL: URL

    public init(id: String, name: String, tagline: String, symbol: String,
                appStoreID: String?, webURL: URL) {
        self.id = id; self.name = name; self.tagline = tagline
        self.symbol = symbol; self.appStoreID = appStoreID; self.webURL = webURL
    }
}

/// Where in this app a link was clicked. Separate tokens per surface so App
/// Store Connect can answer which placement actually earns its space, rather
/// than reporting one undifferentiated "came from the studio".
public enum SiblingAppCampaign: String, Sendable, CaseIterable {
    /// The API/server pane — these apps are clients of the local server, so the
    /// link is genuinely informative there.
    case serverPane = "gvs-server-pane"
    case settings = "gvs-settings"
    case takesEmptyState = "gvs-takes"
}

public enum SiblingApps {
    /// Apple Ads provider token from App Store Connect (App Analytics →
    /// Campaigns). Nil is fine: `ct` alone still records the campaign, `pt`
    /// only groups campaigns under a provider.
    public static let providerToken: String? = nil

    public static let all: [SiblingApp] = [
        SiblingApp(
            id: "gloam",
            name: "Gloam.fm",
            tagline: "An AI DJ that builds the set, works the mic, and takes the "
                + "room's requests live — on your own Apple Music.",
            symbol: "radio",
            appStoreID: nil,
            webURL: URL(string: "https://gloam.fm/radio/")!),
        SiblingApp(
            id: "gloam-mc",
            name: "Gloam MC",
            tagline: "An AI MC that runs the reception, works the room, and takes "
                + "song requests — on your own Apple Music.",
            symbol: "mic",
            appStoreID: nil,
            webURL: URL(string: "https://gloam.fm/mc/")!),
    ]

    /// Where a click on `app` from `campaign` should go.
    ///
    /// Two channels, because only one of them can attribute a Mac App Store
    /// install: `ct` is Apple's own campaign token and surfaces in App Store
    /// Connect App Analytics with no SDK and no privacy-manifest change. The web
    /// fallback carries UTM instead, which the site can attribute itself.
    public static func link(_ app: SiblingApp, campaign: SiblingAppCampaign) -> URL {
        guard let appStoreID = app.appStoreID else {
            var components = URLComponents(url: app.webURL, resolvingAgainstBaseURL: false)!
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "utm_source", value: "gloam-voice-studio"),
                URLQueryItem(name: "utm_medium", value: "app"),
                URLQueryItem(name: "utm_campaign", value: campaign.rawValue),
            ]
            return components.url!
        }
        var components = URLComponents(
            string: "https://apps.apple.com/app/id\(appStoreID)")!
        var items = [URLQueryItem(name: "mt", value: "8"),
                     URLQueryItem(name: "ct", value: campaign.rawValue)]
        if let providerToken { items.append(URLQueryItem(name: "pt", value: providerToken)) }
        components.queryItems = items
        return components.url!
    }
}
