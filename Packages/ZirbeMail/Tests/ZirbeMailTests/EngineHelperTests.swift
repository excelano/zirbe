// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The engine's and sender's pure rules, testable with no connection: the
// transport security each port demands (TLS is required, never opportunistic),
// and the scan for the Content-IDs an HTML body actually paints, so only the
// inline parts the page references ship to the renderer.

import XCTest
import SwiftMail
@testable import ZirbeMail

final class EngineHelperTests: XCTestCase {
    // MARK: Transport security

    func testIMAPRequiresImplicitTLSOn993AndSTARTTLSEverywhereElse() {
        XCTAssertEqual(MailEngine.transportSecurity(port: 993), .implicitTLS)
        XCTAssertEqual(MailEngine.transportSecurity(port: 143), .startTLS)
        XCTAssertEqual(MailEngine.transportSecurity(port: 1143), .startTLS, "a non-standard port never falls to plaintext")
    }

    func testSMTPRequiresImplicitTLSOn465AndSTARTTLSEverywhereElse() {
        XCTAssertEqual(MailSender.transportSecurity(port: 465), .implicitTLS)
        XCTAssertEqual(MailSender.transportSecurity(port: 587), .startTLS)
        XCTAssertEqual(MailSender.transportSecurity(port: 25), .startTLS)
        XCTAssertEqual(MailSender.transportSecurity(port: 2525), .startTLS, "a non-standard port never falls to plaintext")
    }

    // MARK: cid references

    func testReferencedCIDsAreFoundInImagesAndStylesAndNormalized() {
        let html = """
        <img src="cid:Logo@Host"> <img src='cid:<sig@host>'>
        <div style="background:url(cid:bg@host)"></div>
        <p>plain text mentioning CID:Shout@host too</p>
        """

        let ids = MailEngine.referencedCIDs(in: html)

        XCTAssertEqual(ids, ["logo@host", "sig@host", "bg@host", "shout@host"])
    }

    func testReferencedCIDsIsEmptyForABodyWithoutInlineParts() {
        XCTAssertTrue(MailEngine.referencedCIDs(in: "<p>hello</p>").isEmpty)
        XCTAssertTrue(MailEngine.referencedCIDs(in: "").isEmpty)
    }

    func testNormalizeCIDStripsBracketsAndWhitespaceAndLowercases() {
        XCTAssertEqual(MailEngine.normalizeCID("<Logo@Host>"), "logo@host")
        XCTAssertEqual(MailEngine.normalizeCID("  logo@host \t"), "logo@host")
        XCTAssertEqual(MailEngine.normalizeCID("plain"), "plain")
    }

    func testAPartsIDMatchesTheBodysReferenceAfterNormalization() {
        // The typical pairing: the part declares `<id@host>`, the HTML says `cid:id@host`.
        let referenced = MailEngine.referencedCIDs(in: #"<img src="cid:image001@01DA">"#)
        XCTAssertTrue(referenced.contains(MailEngine.normalizeCID("<IMAGE001@01DA>")))
    }
}
