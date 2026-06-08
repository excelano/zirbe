import XCTest
@testable import ZirbeCore

final class AddressParserTests: XCTestCase {
    func testNameAndAngleAddress() {
        let p = AddressParser.parseOne("Dave Anderson <dave@anderix.com>")
        XCTAssertEqual(p?.address, "dave@anderix.com")
        XCTAssertEqual(p?.displayName, "Dave Anderson")
    }

    func testBareAddressHasNoName() {
        let p = AddressParser.parseOne("dave@anderix.com")
        XCTAssertEqual(p?.address, "dave@anderix.com")
        XCTAssertNil(p?.displayName)
    }

    func testQuotedNameWithCommaStaysOneAddress() {
        let list = AddressParser.parseList("\"Anderson, Dave\" <dave@anderix.com>")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.displayName, "Anderson, Dave")
    }

    func testListSplitsOnTopLevelCommas() {
        let list = AddressParser.parseList("a@x.com, Bob <b@y.com>, c@z.com")
        XCTAssertEqual(list.map(\.address), ["a@x.com", "b@y.com", "c@z.com"])
    }

    func testAddressIsLowercased() {
        XCTAssertEqual(AddressParser.parseOne("DAVE@Anderix.COM")?.address, "dave@anderix.com")
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(AddressParser.parseOne("not an address"))
        XCTAssertNil(AddressParser.parseOne(""))
    }
}
