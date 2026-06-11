import XCTest
@testable import ZirbeCore

final class ProviderPresetsTests: XCTestCase {
    func testKnownProviderByDomain() {
        let p = ProviderPresets.preset(forEmail: "someone@fastmail.com")
        XCTAssertEqual(p?.displayName, "Fastmail")
        XCTAssertEqual(p?.imapHost, "imap.fastmail.com")
        XCTAssertEqual(p?.smtpHost, "smtp.fastmail.com")
        XCTAssertEqual(p?.imapPort, 993)
        XCTAssertEqual(p?.smtpPort, 587)
        XCTAssertNotNil(p?.passwordHint)
    }

    func testProviderAliasesShareSettings() {
        let icloud = ProviderPresets.preset(forEmail: "a@icloud.com")
        let me = ProviderPresets.preset(forEmail: "a@me.com")
        let mac = ProviderPresets.preset(forEmail: "a@mac.com")
        XCTAssertEqual(icloud, me)
        XCTAssertEqual(me, mac)
        XCTAssertEqual(icloud?.imapHost, "imap.mail.me.com")
    }

    func testMatchIsCaseInsensitive() {
        let upper = ProviderPresets.preset(forEmail: "Person@GMAIL.COM")
        XCTAssertEqual(upper?.displayName, "Gmail")
        XCTAssertEqual(upper?.imapHost, "imap.gmail.com")
    }

    func testUnknownDomainHasNoPreset() {
        XCTAssertNil(ProviderPresets.preset(forEmail: "dave@anderix.com"))
    }

    func testUnknownDomainGetsSameDomainSuggestion() {
        let s = ProviderPresets.suggestion(forEmail: "dave@anderix.com")
        XCTAssertNil(s?.displayName)
        XCTAssertEqual(s?.imapHost, "imap.anderix.com")
        XCTAssertEqual(s?.smtpHost, "smtp.anderix.com")
    }

    func testResolvePrefersKnownThenFallsBack() {
        XCTAssertEqual(ProviderPresets.resolve(forEmail: "a@yahoo.com")?.displayName, "Yahoo")
        XCTAssertNil(ProviderPresets.resolve(forEmail: "a@example.org")?.displayName)
        XCTAssertEqual(ProviderPresets.resolve(forEmail: "a@example.org")?.imapHost, "imap.example.org")
    }

    func testMalformedAddressYieldsNothing() {
        for bad in ["", "no-at-sign", "@nodomain.com", "nolocal@", "two@@ats.com"] {
            XCTAssertNil(ProviderPresets.preset(forEmail: bad), "preset for \(bad)")
            XCTAssertNil(ProviderPresets.suggestion(forEmail: bad), "suggestion for \(bad)")
        }
    }
}
