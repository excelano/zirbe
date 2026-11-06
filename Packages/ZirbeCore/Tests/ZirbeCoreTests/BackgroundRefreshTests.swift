// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import XCTest
import ZirbeMail
@testable import ZirbeCore

final class BackgroundRefreshTests: XCTestCase {
    private let work = Account(emailAddress: "me@work.com", imapHost: "imap.work.com", smtpHost: "smtp.work.com")
    private let home = Account(emailAddress: "me@home.com", imapHost: "imap.home.com", smtpHost: "smtp.home.com")

    private var store: MailStore!
    private var servers: [String: FakeMailServer] = [:]

    override func setUp() async throws {
        store = try MailStore()
        servers = [work.id: FakeMailServer(), home.id: FakeMailServer()]
        try await store.upsert(work)
        try await store.upsert(home)
    }

    private func poll(_ credentials: FakeCredentials) async -> BackgroundRefreshResult {
        await BackgroundRefresh.run(store: store, credentials: credentials, oauth: OAuthClient()) { [store, servers] account in
            SyncService(account: account, store: store!, engine: servers[account.id]!, sender: FakeMailSender())
        }
    }

    private func deliver(_ subject: String, id: String, to account: Account) async {
        _ = await servers[account.id]!.add(MailEnvelope(
            subject: subject, from: "Pat <pat@x.com>", to: [account.emailAddress],
            date: Date(timeIntervalSince1970: 60), messageID: id
        ))
    }

    func testAPollNotifiesForNewMailInEveryAccount() async throws {
        await deliver("Standup", id: "<w@x>", to: work)
        await deliver("Dinner", id: "<h@x>", to: home)

        let result = await poll(FakeCredentials([work.id: "pw", home.id: "pw"]))

        guard case let .newMail(arrivals, unreadCount) = result else { return XCTFail("expected new mail") }
        XCTAssertEqual(Set(arrivals.map(\.accountID)), [work.id, home.id])
        XCTAssertEqual(Set(arrivals.compactMap(\.subject)), ["Standup", "Dinner"])
        XCTAssertEqual(unreadCount, 2)
    }

    func testTheNextPollIsUpToDate() async throws {
        await deliver("Standup", id: "<w@x>", to: work)
        let credentials = FakeCredentials([work.id: "pw", home.id: "pw"])
        _ = await poll(credentials)

        guard case .upToDate = await poll(credentials) else { return XCTFail("expected nothing new") }
    }

    func testAnAccountWithNoPasswordIsSkipped() async throws {
        await deliver("Standup", id: "<w@x>", to: work)
        await deliver("Dinner", id: "<h@x>", to: home)

        let result = await poll(FakeCredentials([work.id: "pw"]))

        guard case let .newMail(arrivals, _) = result else { return XCTFail("expected new mail") }
        XCTAssertEqual(arrivals.map(\.accountID), [work.id])
        let homeCalls = await servers[home.id]!.calls(.connect)
        XCTAssertTrue(homeCalls.isEmpty)
    }

    func testOneUnreachableAccountDoesNotStopTheOthers() async throws {
        await deliver("Dinner", id: "<h@x>", to: home)
        await servers[work.id]!.rejectPassword()

        let result = await poll(FakeCredentials([work.id: "pw", home.id: "pw"]))

        guard case let .newMail(arrivals, _) = result else { return XCTFail("expected new mail") }
        XCTAssertEqual(arrivals.map(\.accountID), [home.id])
    }

    func testAPollWithNoPasswordsFails() async throws {
        guard case .failed = await poll(FakeCredentials()) else { return XCTFail("expected a failed poll") }
    }
}
