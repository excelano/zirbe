import XCTest
@testable import ZirbeCore

final class MailboxDisplayNameTests: XCTestCase {
    private func mailbox(_ name: String, role: MailboxRole? = nil, delimiter: String? = nil) -> Mailbox {
        Mailbox(accountID: "acct", name: name, role: role, hierarchyDelimiter: delimiter)
    }

    func testInboxReadsAsInbox() {
        XCTAssertEqual(mailbox("INBOX", role: .inbox, delimiter: ".").displayName, "Inbox")
        XCTAssertEqual(mailbox("INBOX", delimiter: "/").displayName, "Inbox")
    }

    func testDottedFoldersUnderInboxShowLeaf() {
        XCTAssertEqual(mailbox("INBOX.Drafts", role: .drafts, delimiter: ".").displayName, "Drafts")
        XCTAssertEqual(mailbox("INBOX.Sent", role: .sent, delimiter: ".").displayName, "Sent")
        XCTAssertEqual(mailbox("INBOX.Archive", role: .archive, delimiter: ".").displayName, "Archive")
        XCTAssertEqual(mailbox("INBOX.Trash", role: .trash, delimiter: ".").displayName, "Trash")
    }

    func testSlashDelimitedPathsShowLeaf() {
        XCTAssertEqual(mailbox("[Gmail]/Sent Mail", role: .sent, delimiter: "/").displayName, "Sent Mail")
    }

    /// A literal dot in a Gmail label must survive: "." is not Gmail's delimiter,
    /// so the name is only split on "/".
    func testDottedLabelOnSlashServerIsNotTruncated() {
        XCTAssertEqual(mailbox("node.js", delimiter: "/").displayName, "node.js")
        XCTAssertEqual(mailbox("Work/v2.0", delimiter: "/").displayName, "v2.0")
    }

    func testTopLevelFolderUnchanged() {
        XCTAssertEqual(mailbox("Receipts", delimiter: ".").displayName, "Receipts")
    }

    /// No known delimiter (a cached row before its first folder refresh): leave the
    /// name whole rather than guess and risk truncating it.
    func testUnknownDelimiterLeavesNameWhole() {
        XCTAssertEqual(mailbox("INBOX.Sent", role: .sent).displayName, "INBOX.Sent")
    }
}
