import XCTest
@testable import ZirbeMail

/// Masking the account address before it reaches a debug log. Zirbe sends nothing
/// anywhere, but a log line still lands in the device's log store, and the local
/// part is the half that names the person.
final class LogRedactionTests: XCTestCase {
    func testTheLocalPartGoesAndTheDomainStays() {
        XCTAssertEqual(LogRedaction.address("david@excelano.com"), "•••@excelano.com")
        XCTAssertEqual(LogRedaction.address("first.last+tag@mail.example.co.uk"), "•••@mail.example.co.uk")
    }

    /// Anything that isn't an address is masked whole rather than guessed at, so a
    /// malformed or unexpected value can't slip through in one piece.
    func testAnythingNotAnAddressIsMaskedWhole() {
        for odd in ["", "notanaddress", "@leading", "trailing@", "@"] {
            let masked = LogRedaction.address(odd)
            XCTAssertFalse(masked.contains(where: \.isLetter), "\"\(odd)\" masked to \"\(masked)\"")
        }
    }

    /// The point of the exercise: the address must not survive anywhere in the
    /// result, including the local part appearing after the domain.
    func testTheAddressNeverSurvivesInFull() {
        let address = "david@excelano.com"
        XCTAssertFalse(LogRedaction.address(address).contains("david"))
    }
}
