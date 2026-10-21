import XCTest
@testable import FocusGuard

/// Site icons come from the sites themselves, and the privacy text says what
/// actually goes online.
final class PrivacyCopyTests: XCTestCase {
    private let base = URL(string: "https://example.com/")!

    func test_onlyPlainHostnamesAreFetched() {
        XCTAssertTrue(FaviconLoader.isFetchable("youtube.com"))
        XCTAssertTrue(FaviconLoader.isFetchable("m.news-site.co.uk"))
        XCTAssertFalse(FaviconLoader.isFetchable("localhost"))
        XCTAssertFalse(FaviconLoader.isFetchable(""))
        XCTAssertFalse(FaviconLoader.isFetchable("evil.com/path"))
        XCTAssertFalse(FaviconLoader.isFetchable("evil.com:8080"))
        XCTAssertFalse(FaviconLoader.isFetchable(".example.com"))
    }

    func test_iconLinks_prefersTouchIconsAndResolvesRelativePaths() {
        let html = """
        <head>
          <link rel="stylesheet" href="/site.css">
          <link rel="icon" type="image/png" href="/static/icon-32.png">
          <LINK REL='apple-touch-icon' HREF='https://cdn.example.com/touch.png'>
          <link rel="shortcut icon" href=favicon.ico>
        </head>
        """
        XCTAssertEqual(FaviconLoader.iconLinks(in: html, base: base).map(\.absoluteString), [
            "https://cdn.example.com/touch.png",
            "https://example.com/static/icon-32.png",
            "https://example.com/favicon.ico",
        ])
    }

    func test_iconLinks_skipsSVGAndDataURLs() {
        let html = """
        <link rel="icon" href="/icon.svg">
        <link rel="icon" type="image/svg+xml" href="/mask">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="mask-icon" href="ftp://example.com/a.png">
        """
        XCTAssertEqual(FaviconLoader.iconLinks(in: html, base: base), [])
    }

    func test_privacyStatement_namesWhatGoesOnline() {
        let text = PrivacyStatement.network
        XCTAssertTrue(text.contains("updates"))
        XCTAssertTrue(text.contains("site icons"))
        XCTAssertTrue(text.contains("Spotify"))
        XCTAssertFalse(text.contains("Nothing is sent"))
        XCTAssertEqual(text.contains("AI tips"), AISettings.isAvailable)
        XCTAssertEqual(PrivacyStatement.short.contains("AI tips"), AISettings.isAvailable)
    }

    func test_categoryNames_areOneWordEach() {
        XCTAssertEqual(Classification.allCases.map(categoryName), ["Focus", "Neutral", "Distracting"])
    }
}
