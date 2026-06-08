import XCTest
@testable import ZirbeMail

final class MailEnvelopeTests: XCTestCase {
    func testIdentityPrefersUID() {
        let envelope = MailEnvelope(sequenceNumber: 3, uid: 42, messageID: "<a@b>")
        XCTAssertEqual(envelope.id, "uid:42")
    }

    func testIdentityFallsBackToMessageID() {
        let envelope = MailEnvelope(sequenceNumber: 3, messageID: "<a@b>")
        XCTAssertEqual(envelope.id, "mid:<a@b>")
    }

    func testIdentityFallsBackToSequence() {
        let envelope = MailEnvelope(sequenceNumber: 3)
        XCTAssertEqual(envelope.id, "seq:3")
    }
}
