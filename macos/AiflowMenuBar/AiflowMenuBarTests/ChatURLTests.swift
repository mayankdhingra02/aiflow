import XCTest

@testable import AiflowMenuBar

final class ChatURLTests: XCTestCase {
    func testPlainConversationURLIsUnchanged() {
        XCTAssertEqual(
            ChatURL.normalize("https://chatgpt.com/c/abc123"),
            "https://chatgpt.com/c/abc123"
        )
    }

    func testQueryStringIsStripped() {
        XCTAssertEqual(
            ChatURL.normalize("https://chatgpt.com/c/abc123?foo=1"),
            "https://chatgpt.com/c/abc123"
        )
    }

    func testFragmentAndQueryAreStripped() {
        XCTAssertEqual(
            ChatURL.normalize("https://chatgpt.com/c/abc123?foo=bar&baz=2#section"),
            "https://chatgpt.com/c/abc123"
        )
    }

    func testTrailingSlashIsIgnored() {
        XCTAssertEqual(
            ChatURL.normalize("https://chatgpt.com/c/abc123/"),
            "https://chatgpt.com/c/abc123"
        )
    }

    func testWWWHostIsCanonicalized() {
        XCTAssertEqual(
            ChatURL.normalize("https://www.chatgpt.com/c/abc123"),
            "https://chatgpt.com/c/abc123"
        )
    }

    func testLegacyOpenAIHostMapsToSameKey() {
        XCTAssertEqual(
            ChatURL.normalize("https://chat.openai.com/c/abc123"),
            "https://chatgpt.com/c/abc123"
        )
    }

    func testGPTScopedConversationMapsToSameKey() {
        XCTAssertEqual(
            ChatURL.normalize("https://chatgpt.com/g/g-xyz789/c/abc123"),
            "https://chatgpt.com/c/abc123"
        )
    }

    func testNonChatGPTURLIsNil() {
        XCTAssertNil(ChatURL.normalize("https://example.com/c/abc123"))
    }

    func testChatGPTHomeWithoutConversationIsNil() {
        XCTAssertNil(ChatURL.normalize("https://chatgpt.com/"))
    }

    func testChatGPTNonConversationPathIsNil() {
        XCTAssertNil(ChatURL.normalize("https://chatgpt.com/gpts"))
    }

    func testConversationMarkerWithoutIDIsNil() {
        XCTAssertNil(ChatURL.normalize("https://chatgpt.com/c/"))
    }

    func testNilAndEmptyInputAreNil() {
        XCTAssertNil(ChatURL.normalize(nil))
        XCTAssertNil(ChatURL.normalize(""))
        XCTAssertNil(ChatURL.normalize("   "))
    }

    func testGarbageInputIsNil() {
        XCTAssertNil(ChatURL.normalize("not a url"))
    }

    func testConversationIDExtraction() {
        XCTAssertEqual(
            ChatURL.conversationID(from: "https://chatgpt.com/c/abc123"),
            "abc123"
        )
    }
}

final class BrowserURLDetectorTests: XCTestCase {
    func testUsesFirstBrowserThatReturnsAConversation() {
        var seenScripts: [String] = []
        let detected = BrowserURLDetector.detectChatURL { script in
            seenScripts.append(script)
            return "https://chatgpt.com/c/fromchrome?x=1"
        }

        XCTAssertEqual(detected, "https://chatgpt.com/c/fromchrome")
        // Chrome is consulted first and short-circuits Safari.
        XCTAssertEqual(seenScripts.count, 1)
        XCTAssertEqual(seenScripts.first, BrowserURLDetector.chromeScript)
    }

    func testFallsBackToSafariWhenChromeHasNoConversation() {
        let detected = BrowserURLDetector.detectChatURL { script in
            script == BrowserURLDetector.chromeScript
                ? "https://news.example.com" : "https://chatgpt.com/c/fromsafari"
        }

        XCTAssertEqual(detected, "https://chatgpt.com/c/fromsafari")
    }

    func testReturnsNilWhenNoBrowserHasAConversation() {
        XCTAssertNil(BrowserURLDetector.detectChatURL { _ in nil })
    }

    func testScriptsGuardAgainstLaunchingABrowser() {
        // A bare `tell application` would launch the browser; both scripts must check first.
        XCTAssertTrue(BrowserURLDetector.chromeScript.contains("is running"))
        XCTAssertTrue(BrowserURLDetector.safariScript.contains("is running"))
    }
}
