import XCTest
@testable import ZirbeCore

final class ConversationDefaultsTests: XCTestCase {
    private let me = "me@x.com"

    private func p(_ address: String, _ name: String? = nil) -> Participant {
        Participant(address: address, displayName: name)
    }

    func testNamedSubjectIsUsedVerbatim() {
        let title = ConversationDefaults.displayTitle(
            subject: "Lunch Friday",
            participants: [p("me@x.com"), p("sarah@x.com", "Sarah")],
            selfAddress: me
        )
        XCTAssertEqual(title, "Lunch Friday")
    }

    func testDefaultSubjectTitlesByTheOtherParticipant() {
        let title = ConversationDefaults.displayTitle(
            subject: ConversationDefaults.unnamedSubject,
            participants: [p("me@x.com"), p("sarah@x.com", "Sarah")],
            selfAddress: me
        )
        XCTAssertEqual(title, "Chat with Sarah")
    }

    func testEmptySubjectTitlesByTheOtherParticipants() {
        let title = ConversationDefaults.displayTitle(
            subject: "   ",
            participants: [p("sarah@x.com", "Sarah"), p("tom@x.com", "Tom")],
            selfAddress: me
        )
        XCTAssertEqual(title, "Chat with Sarah, Tom")
    }

    func testSelfIsExcludedAndMatchedCaseInsensitively() {
        let title = ConversationDefaults.displayTitle(
            subject: "",
            participants: [p("ME@X.com"), p("tom@x.com", "Tom")],
            selfAddress: me
        )
        XCTAssertEqual(title, "Chat with Tom")
    }

    func testFallbackCapsAtThreeNames() {
        let title = ConversationDefaults.displayTitle(
            subject: "",
            participants: [p("a@x.com", "A"), p("b@x.com", "B"), p("c@x.com", "C"), p("d@x.com", "D")],
            selfAddress: me
        )
        XCTAssertEqual(title, "Chat with A, B, C")
    }

    func testNoteToSelfKeepsTheBareDefault() {
        let title = ConversationDefaults.displayTitle(
            subject: ConversationDefaults.unnamedSubject,
            participants: [p("me@x.com")],
            selfAddress: me
        )
        XCTAssertEqual(title, "Chat")
    }
}
