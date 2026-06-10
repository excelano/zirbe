import XCTest
@testable import ZirbeMail

final class HTMLTextTests: XCTestCase {
    func testStripsTagsKeepingText() {
        let html = "<p>Hello <strong>there</strong>, friend.</p>"
        XCTAssertEqual(HTMLText.plainText(from: html), "Hello there, friend.")
    }

    func testDropsScriptAndStyleContentsWholesale() {
        let html = """
        <html><head><title>Ignore me</title></head>
        <style>.x{color:red}</style>
        <body><p>Visible.</p><script>alert('no')</script></body></html>
        """
        XCTAssertEqual(HTMLText.plainText(from: html), "Visible.")
    }

    func testBlockBoundariesBecomeLineBreaks() {
        let html = "<p>First</p><p>Second</p>line<br>break"
        XCTAssertEqual(HTMLText.plainText(from: html), "First\nSecond\nline\nbreak")
    }

    func testDecodesNamedAndNumericEntities() {
        let html = "<p>A &amp; B &lt; C &#39;quote&#39; &#x2014; end &nbsp;done</p>"
        XCTAssertEqual(HTMLText.plainText(from: html), "A & B < C 'quote' \u{2014} end done")
    }

    func testAmpersandEntityResolvesLast() {
        // &amp;lt; should read as the literal text "&lt;", not as "<".
        XCTAssertEqual(HTMLText.decodeEntities("&amp;lt;"), "&lt;")
    }

    func testCollapsesWhitespaceAndBlankRuns() {
        let html = "<div>one</div>\n\n\n\n<div>two</div>    trailing   spaces"
        XCTAssertEqual(HTMLText.plainText(from: html), "one\n\ntwo\ntrailing spaces")
    }

    func testEmptyMarkupReducesToEmpty() {
        XCTAssertEqual(HTMLText.plainText(from: "<style>.a{}</style><div></div>"), "")
    }
}
