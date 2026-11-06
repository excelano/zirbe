// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import XCTest
import ZirbeMail
@testable import ZirbeCore

@MainActor
final class AppSessionTests: XCTestCase {
    private let work = Account(emailAddress: "me@work.com", imapHost: "imap.work.com", smtpHost: "smtp.work.com")
    private let home = Account(emailAddress: "me@home.com", imapHost: "imap.home.com", smtpHost: "smtp.home.com")

    private var store: MailStore!
    private var credentials: FakeCredentials!
    private var servers: [String: FakeMailServer] = [:]
    private var defaults: UserDefaults!

    override func setUp() async throws {
        store = try MailStore()
        credentials = FakeCredentials()
        servers = [work.id: FakeMailServer(), home.id: FakeMailServer()]
        defaults = UserDefaults(suiteName: "AppSessionTests-\(UUID().uuidString)")
    }

    private func makeSession() -> AppSession {
        AppSession(
            credentials: credentials,
            openStore: { [store] in store! },
            makeModel: { [servers] account, store in
                let sync = SyncService(account: account, store: store, engine: servers[account.id]!, sender: FakeMailSender())
                return InboxModel(account: account, store: store, sync: sync)
            },
            defaults: defaults
        )
    }

    private func envelope(_ subject: String, id: String, to: String) -> MailEnvelope {
        MailEnvelope(subject: subject, from: "Pat <pat@x.com>", to: [to], date: Date(timeIntervalSince1970: 60), messageID: id)
    }

    private func connectBoth(_ session: AppSession) async throws {
        _ = await servers[work.id]!.add(envelope("Standup", id: "<w@x>", to: work.emailAddress))
        _ = await servers[home.id]!.add(envelope("Dinner", id: "<h@x>", to: home.emailAddress))
        try await session.connect(account: work, password: "work-pw")
        try await session.connect(account: home, password: "home-pw")
    }

    func testConnectingASecondAccountKeepsTheFirstAndSwitchesToTheNew() async throws {
        let session = makeSession()
        try await connectBoth(session)

        XCTAssertEqual(session.accounts.map(\.id), [work.id, home.id])
        XCTAssertEqual(session.model?.account.id, home.id)
        XCTAssertTrue(session.models.allSatisfy(\.isConnected))
        XCTAssertEqual(credentials.stored, [work.id: "work-pw", home.id: "home-pw"])
    }

    func testSelectingAnAccountSwitchesTheModel() async throws {
        let session = makeSession()
        try await connectBoth(session)

        await session.select(work.id)

        XCTAssertEqual(session.model?.account.id, work.id)
        XCTAssertEqual(session.model?.summaries.map(\.subject), ["Standup"])
    }

    func testRestoreResumesEveryAccountAndReturnsToTheLastViewed() async throws {
        let first = makeSession()
        try await connectBoth(first)
        await first.select(work.id)

        let restored = makeSession()
        await restored.restore()

        XCTAssertEqual(restored.accounts.map(\.id), [work.id, home.id])
        XCTAssertTrue(restored.models.allSatisfy(\.isConnected))
        XCTAssertEqual(restored.model?.account.id, work.id)
        XCTAssertEqual(restored.model?.summaries.map(\.subject), ["Standup"])
    }

    func testRestoreKeepsAnAccountWithNoPasswordForReentry() async throws {
        try await connectBoth(makeSession())
        credentials = FakeCredentials([work.id: "work-pw"])

        let restored = makeSession()
        await restored.restore()

        XCTAssertEqual(restored.restoredAccount?.id, home.id)
        await restored.select(work.id)
        XCTAssertNil(restored.restoredAccount)
        XCTAssertTrue(restored.isConnected)
    }

    func testReconnectingAnAccountReplacesItsSession() async throws {
        let session = makeSession()
        try await connectBoth(session)
        let before = session.models.first { $0.account.id == work.id }

        try await session.connect(account: work, password: "new-pw")

        XCTAssertEqual(session.models.count, 2)
        XCTAssertFalse(session.models.contains { $0 === before })
        XCTAssertEqual(credentials.stored[work.id], "new-pw")
    }

    func testRemovingOneAccountKeepsTheOthersMail() async throws {
        let session = makeSession()
        try await connectBoth(session)

        await session.remove(home.id)

        XCTAssertEqual(session.accounts.map(\.id), [work.id])
        XCTAssertEqual(session.model?.account.id, work.id)
        XCTAssertNil(credentials.stored[home.id])
        let accounts = try await store.accounts()
        XCTAssertEqual(accounts.map(\.id), [work.id])
        let homeMail = try await store.threadSummaries(accountID: home.id)
        let workMail = try await store.threadSummaries(accountID: work.id)
        XCTAssertTrue(homeMail.isEmpty)
        XCTAssertEqual(workMail.map(\.subject), ["Standup"])
    }

    func testRemovingTheLastAccountWipesTheStore() async throws {
        let session = makeSession()
        try await connectBoth(session)

        await session.remove(home.id)
        await session.remove(work.id)

        XCTAssertNil(session.model)
        XCTAssertTrue(credentials.stored.isEmpty)
        let accounts = try await store.accounts()
        XCTAssertTrue(accounts.isEmpty)
    }

    func testEachNewAccountGetsAColourNotYetInUse() async throws {
        let session = makeSession()
        try await connectBoth(session)

        XCTAssertEqual(session.accounts.map(\.color), [.blue, .green])
    }

    func testALabelAndColourSurviveASyncAndARestore() async throws {
        let session = makeSession()
        try await connectBoth(session)

        await session.setAppearance(label: "Work", color: .purple, accountID: work.id)
        await session.select(work.id)
        await session.model?.refresh()

        XCTAssertEqual(session.model?.account.title, "Work")
        let restored = makeSession()
        await restored.restore()
        let account = restored.accounts.first { $0.id == work.id }
        XCTAssertEqual(account?.label, "Work")
        XCTAssertEqual(account?.color, .purple)
    }

    func testReconnectingKeepsTheLabelAndColour() async throws {
        let session = makeSession()
        try await connectBoth(session)
        await session.setAppearance(label: "Work", color: .purple, accountID: work.id)

        try await session.connect(account: work, password: "new-pw")

        let account = session.accounts.first { $0.id == work.id }
        XCTAssertEqual(account?.label, "Work")
        XCTAssertEqual(account?.color, .purple)
    }

    func testAnUnlabelledAccountIsTitledByItsAddress() {
        XCTAssertEqual(work.title, "me@work.com")
        var labelled = work
        labelled.label = "  "
        XCTAssertEqual(labelled.title, "me@work.com")
    }

    func testTheInboxUnreadCountSumsEveryAccount() async throws {
        let session = makeSession()
        try await connectBoth(session)

        XCTAssertEqual(session.inboxUnreadCount, 2)
    }
}
