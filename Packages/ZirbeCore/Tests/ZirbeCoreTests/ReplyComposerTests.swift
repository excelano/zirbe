// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The reply bar's send-and-restore rule: Send takes the whole draft out of the
// bar at once, and a refused send puts it back only if the bar is still empty.

import XCTest
@testable import ZirbeCore

final class ReplyComposerTests: XCTestCase {
    private let target = Message(messageID: "<a@x>", subject: "Plan", from: Participant(address: "pat@x.com"))

    func testEmptinessIgnoresWhitespaceButNotFiles() {
        var composer = ReplyComposer<String>()
        XCTAssertTrue(composer.isEmpty)
        composer.text = " \n "
        XCTAssertTrue(composer.isEmpty)
        composer.attachments = ["photo"]
        XCTAssertTrue(composer.isEmpty == false)
    }

    func testTakeClearsTheBarAndReturnsEverything() {
        var composer = ReplyComposer(text: "Yes", attachments: ["photo"], target: target)

        let taken = composer.take()

        XCTAssertEqual(taken.text, "Yes")
        XCTAssertEqual(taken.attachments, ["photo"])
        XCTAssertEqual(taken.target?.messageID, "<a@x>")
        XCTAssertEqual(composer.text, "")
        XCTAssertTrue(composer.attachments.isEmpty)
        XCTAssertNil(composer.target)
    }

    func testARefusedSendPutsTheDraftBackIntoAnEmptyBar() {
        var composer = ReplyComposer(text: "Yes", attachments: ["photo"], target: target)
        let taken = composer.take()

        XCTAssertTrue(composer.restore(taken))

        XCTAssertEqual(composer.text, "Yes")
        XCTAssertEqual(composer.attachments, ["photo"])
        XCTAssertEqual(composer.target?.messageID, "<a@x>")
    }

    func testARefusedSendNeverOverwritesWhatWasTypedSince() {
        var composer = ReplyComposer<String>(text: "Yes", target: target)
        let taken = composer.take()
        composer.text = "N"

        XCTAssertFalse(composer.restore(taken))

        XCTAssertEqual(composer.text, "N")
        XCTAssertNil(composer.target, "the old target doesn't come back either")
    }

    func testAFileAttachedSinceAlsoBlocksTheRestore() {
        var composer = ReplyComposer<String>(text: "Yes")
        let taken = composer.take()
        composer.attachments = ["new.pdf"]

        XCTAssertFalse(composer.restore(taken))
        XCTAssertEqual(composer.attachments, ["new.pdf"])
    }
}
