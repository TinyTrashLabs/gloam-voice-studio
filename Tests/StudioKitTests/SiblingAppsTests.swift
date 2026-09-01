import XCTest
@testable import StudioKit

final class SiblingAppsTests: XCTestCase {
    private func app(appStoreID: String?) -> SiblingApp {
        SiblingApp(id: "gloam", name: "Gloam.fm", tagline: "t", symbol: "radio",
                   appStoreID: appStoreID, webURL: URL(string: "https://gloam.fm")!)
    }

    /// The state every sibling is in today: no App Store listing yet. A link
    /// must reach the marketing site rather than an App Store error page.
    func testUnshippedAppLinksToTheWebWithUTM() {
        let url = SiblingApps.link(app(appStoreID: nil), campaign: .settings)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        XCTAssertEqual(url.host, "gloam.fm")
        XCTAssertFalse(url.absoluteString.contains("apps.apple.com"))
        XCTAssertEqual(items.first { $0.name == "utm_campaign" }?.value, "gvs-settings")
        XCTAssertEqual(items.first { $0.name == "utm_source" }?.value, "gloam-voice-studio")
    }

    func testShippedAppLinksToTheAppStoreWithACampaignToken() {
        let url = SiblingApps.link(app(appStoreID: "123456789"), campaign: .serverPane)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        XCTAssertEqual(url.host, "apps.apple.com")
        XCTAssertTrue(url.path.contains("id123456789"))
        XCTAssertEqual(items.first { $0.name == "ct" }?.value, "gvs-server-pane")
        XCTAssertEqual(items.first { $0.name == "mt" }?.value, "8")
    }

    /// Distinct tokens are the whole point — one per surface, so App Store
    /// Connect can say which placement earned the install.
    func testEverySurfaceHasItsOwnToken() {
        let tokens = SiblingAppCampaign.allCases.map(\.rawValue)
        XCTAssertEqual(Set(tokens).count, tokens.count)
    }

    func testCatalogIsWellFormed() {
        XCTAssertFalse(SiblingApps.all.isEmpty)
        let ids = SiblingApps.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for app in SiblingApps.all {
            XCTAssertFalse(app.name.isEmpty)
            XCTAssertFalse(app.tagline.isEmpty)
        }
    }
}
