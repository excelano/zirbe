// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import XCTest
@testable import ZirbeMail

final class DeadlineTests: XCTestCase {
    func testAnOperationThatFinishesInTimeReturnsItsValue() async throws {
        let value = try await withDeadline(.seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testAnOperationThatNeverAnswersTimesOut() async {
        let started = ContinuousClock.now
        do {
            _ = try await withDeadline(.milliseconds(100)) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
            XCTFail("expected the deadline to pass")
        } catch {
            XCTAssertEqual(error as? MailEngineError, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testAnOperationsOwnErrorPassesThrough() async {
        do {
            _ = try await withDeadline(.seconds(5)) { throw MailEngineError.authenticationRejected }
            XCTFail("expected the operation's error")
        } catch {
            XCTAssertEqual(error as? MailEngineError, .authenticationRejected)
        }
    }
}
