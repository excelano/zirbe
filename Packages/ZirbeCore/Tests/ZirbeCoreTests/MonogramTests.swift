import XCTest
@testable import ZirbeCore

final class MonogramTests: XCTestCase {
    // MARK: - Initials

    func testInitialsFromTwoWordName() {
        XCTAssertEqual(Monogram.initials(displayName: "Pat Lee", address: "x@y.com"), "PL")
    }

    func testInitialsUsesFirstAndLastWordOfLongName() {
        XCTAssertEqual(Monogram.initials(displayName: "Pat Quincy Lee", address: "x@y.com"), "PL")
    }

    func testInitialsFromSingleWordName() {
        XCTAssertEqual(Monogram.initials(displayName: "Madonna", address: "x@y.com"), "M")
    }

    func testInitialsAreUppercased() {
        XCTAssertEqual(Monogram.initials(displayName: "pat lee", address: "x@y.com"), "PL")
    }

    func testInitialsFallBackToLocalPartWhenNoName() {
        // No display name: derive from the address, splitting the local part on
        // its separators so "pat.lee" reads "PL".
        XCTAssertEqual(Monogram.initials(displayName: nil, address: "pat.lee@example.com"), "PL")
    }

    func testInitialsFromSingleTokenLocalPart() {
        XCTAssertEqual(Monogram.initials(displayName: nil, address: "pat@example.com"), "P")
    }

    func testInitialsFromUnderscoreSeparators() {
        XCTAssertEqual(Monogram.initials(displayName: nil, address: "jay_kay@example.com"), "JK")
    }

    func testInitialsEmptyWhenNoLetterOrDigit() {
        // A name of only punctuation yields nothing, so the view shows a glyph.
        XCTAssertEqual(Monogram.initials(displayName: "!!!", address: "...@example.com"), "")
    }

    func testInitialsFromDigitLocalPart() {
        XCTAssertEqual(Monogram.initials(displayName: nil, address: "4ever@example.com"), "4")
    }

    // MARK: - Palette index

    func testPaletteIndexIsInRange() {
        for address in ["a@x.com", "b@x.com", "someone.long@example.org", "z@z.z"] {
            let index = Monogram.paletteIndex(for: address, count: 8)
            XCTAssertTrue((0..<8).contains(index), "\(address) -> \(index) out of range")
        }
    }

    func testPaletteIndexIsStableAcrossCalls() {
        let a = Monogram.paletteIndex(for: "pat@example.com", count: 8)
        let b = Monogram.paletteIndex(for: "pat@example.com", count: 8)
        XCTAssertEqual(a, b)
    }

    func testPaletteIndexIsCaseInsensitive() {
        XCTAssertEqual(
            Monogram.paletteIndex(for: "Pat@Example.com", count: 8),
            Monogram.paletteIndex(for: "pat@example.com", count: 8)
        )
    }

    func testPaletteIndexZeroCountIsSafe() {
        XCTAssertEqual(Monogram.paletteIndex(for: "x@y.com", count: 0), 0)
    }
}
