import XCTest
@testable import TrackDownloaderCore

final class SoundCloudSignInTests: XCTestCase {
    func testOffNeverPassesCookies() {
        XCTAssertNil(SoundCloudSignIn.off.cookiesBrowser(for: URL(string: "https://soundcloud.com/a/b")!))
    }

    func testOnlySoundCloudLinksBorrowTheLogin() {
        let signIn = SoundCloudSignIn(browser: .chrome, profile: "")

        XCTAssertEqual(signIn.cookiesBrowser(for: URL(string: "https://soundcloud.com/a/b")!), "chrome")
        XCTAssertEqual(signIn.cookiesBrowser(for: URL(string: "https://m.soundcloud.com/a/b")!), "chrome")
        XCTAssertEqual(signIn.cookiesBrowser(for: URL(string: "https://on.soundcloud.com/xyz")!), "chrome")
        XCTAssertNil(signIn.cookiesBrowser(for: URL(string: "https://youtu.be/example")!))
        XCTAssertNil(signIn.cookiesBrowser(for: URL(string: "https://notsoundcloud.com/a/b")!))
        XCTAssertNil(signIn.cookiesBrowser(for: URL(string: "https://soundcloud.com.example.net/a")!))
    }

    func testAddsProfileForBrowsersThatHaveThem() {
        XCTAssertEqual(
            SoundCloudSignIn(browser: .chrome, profile: " Profile 9 ").cookiesFromBrowserValue,
            "chrome:Profile 9"
        )
        XCTAssertEqual(SoundCloudSignIn(browser: .safari, profile: "Work").cookiesFromBrowserValue, "safari")
    }

    func testRefusesProfilesYTDLPWouldMisread() {
        XCTAssertNil(SoundCloudSignIn(browser: .chrome, profile: "a:b").cookiesFromBrowserValue)
        XCTAssertNil(SoundCloudSignIn(browser: .firefox, profile: "x+gnomekeyring").cookiesFromBrowserValue)
    }

    func testPreflightPassesCookiesOnlyWhenGiven() {
        let source = URL(string: "https://soundcloud.com/a/b")!
        XCTAssertFalse(SourcePreflightCommandBuilder.arguments(sourceURL: source).contains("--cookies-from-browser"))
        let arguments = SourcePreflightCommandBuilder.arguments(sourceURL: source, cookiesBrowser: "chrome:Default")
        XCTAssertEqual(arguments.last, source.absoluteString)
        XCTAssertEqual(arguments[arguments.count - 2], "chrome:Default")
        XCTAssertEqual(arguments[arguments.count - 3], "--cookies-from-browser")
    }

    func testScrubberRemovesFormatCookiesAndCredentialHeaders() throws {
        let json = """
        {"title":"Night Drive","cookies":"oauth_token=SECRET; Domain=.soundcloud.com",
         "http_headers":{"User-Agent":"x","Cookie":"a=SECRET","authorization":"OAuth SECRET"},
         "formats":[{"format_id":"download","cookies":"sc_anonymous_id=SECRET","http_headers":{"Accept":"*/*"}}]}
        """
        let cleaned = try XCTUnwrap(InfoJSONCredentialScrubber.scrubbed(Data(json.utf8)))
        let text = String(decoding: cleaned, as: UTF8.self)

        XCTAssertFalse(text.contains("SECRET"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: cleaned) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Night Drive")
        XCTAssertEqual((object["http_headers"] as? [String: Any])?["User-Agent"] as? String, "x")
        XCTAssertEqual(((object["formats"] as? [[String: Any]])?.first)?["format_id"] as? String, "download")
    }

    func testScrubberLeavesCleanOrUnreadableFilesAlone() {
        XCTAssertNil(InfoJSONCredentialScrubber.scrubbed(Data(#"{"title":"x","tags":["cookies"]}"#.utf8)))
        XCTAssertNil(InfoJSONCredentialScrubber.scrubbed(Data("{not json".utf8)))
    }
}
