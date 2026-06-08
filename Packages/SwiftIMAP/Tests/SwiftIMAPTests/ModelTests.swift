import XCTest
@testable import SwiftIMAP

final class ModelTests: XCTestCase {
    func testAddressDescriptionPrefersNameAndEmail() {
        let address = Address(name: "David Anderson", mailbox: "david", host: "anderix.com")
        XCTAssertEqual(address.email, "david@anderix.com")
        XCTAssertEqual(address.description, "David Anderson <david@anderix.com>")
    }

    func testAddressDescriptionFallsBackToEmail() {
        let address = Address(mailbox: "no-reply", host: "example.com")
        XCTAssertEqual(address.description, "no-reply@example.com")
    }

    func testMessageRangeNormalizesOrder() {
        let range = MessageRange(10, through: 3)
        XCTAssertEqual(range.lowerBound, 3)
        XCTAssertEqual(range.upperBound, 10)
    }
}
