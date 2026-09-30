// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A meeting is a conversation: the invitation, its updates, its cancellation,
// and every attendee's answer thread together by the meeting's UID whatever
// the mail headers say; an update replaces the card in place; an answer reads
// as a line, not a bubble. Covered here at the threader, the thread's rules,
// the store, and the sync against the fake server.

import XCTest
import ZirbeMail
@testable import ZirbeCore

final class InviteThreadingTests: XCTestCase {
    private let pat = Participant(address: "pat@x.com", displayName: "Pat")
    private let sam = Participant(address: "sam@x.com", displayName: "Sam")
    private let me = Participant(address: "me@x.com")

    private func invite(_ uid: String, sequence: Int = 0, method: Invite.Method = .request, summary: String = "Lunch", cancelled: Bool = false, replyFrom: Invite.Attendee? = nil) -> Invite {
        Invite(uid: uid, sequence: sequence, method: method, summary: summary,
               attendees: replyFrom.map { [$0] } ?? [], isCancelled: cancelled)
    }

    private func message(_ id: String, from: Participant, minutes: Int, subject: String = "Lunch", inReplyTo: String? = nil, invite: Invite? = nil, body: String? = nil) -> Message {
        Message(messageID: id, inReplyTo: inReplyTo, references: inReplyTo.map { [$0] } ?? [], subject: subject,
                from: from, to: [me], date: Date(timeIntervalSince1970: TimeInterval(minutes * 60)),
                flags: [.seen], bodyText: body, invite: invite)
    }

    // MARK: Threader

    func testMessagesAboutOneMeetingThreadTogetherWithoutHeaders() {
        let first = message("<a@x>", from: pat, minutes: 0, invite: invite("M1"))
        let update = message("<b@x>", from: pat, minutes: 10, subject: "Updated: Lunch", invite: invite("M1", sequence: 1))
        let reply = message("<c@x>", from: sam, minutes: 20, subject: "Accepted: Lunch",
                            invite: invite("M1", method: .reply, replyFrom: .init(name: "Sam", address: "sam@x.com", status: .accepted)))
        let other = message("<d@x>", from: pat, minutes: 30, subject: "Dinner", invite: invite("M2", summary: "Dinner"))

        let threads = Threader.thread([first, update, reply, other])

        XCTAssertEqual(threads.count, 2)
        let lunch = try? XCTUnwrap(threads.first { $0.messages.contains { $0.messageID == "<a@x>" } })
        XCTAssertEqual(Set(lunch?.messages.compactMap(\.messageID) ?? []), ["<a@x>", "<b@x>", "<c@x>"])
        XCTAssertEqual(lunch?.id, "mid:<a@x>", "the earliest message names the thread, not the synthetic meeting root")
        XCTAssertEqual(lunch?.subject, "Lunch")
    }

    func testAMeetingThreadKeepsItsIDAsUpdatesArrive() {
        let first = message("<a@x>", from: pat, minutes: 0, invite: invite("M1"))
        let before = Threader.thread([first]).first?.id
        let update = message("<b@x>", from: pat, minutes: 10, invite: invite("M1", sequence: 1))
        let after = Threader.thread([first, update]).first?.id
        XCTAssertEqual(before, "mid:<a@x>")
        XCTAssertEqual(after, before, "no re-root when an update lands")
    }

    func testAnOrdinaryReplyToAnInviteStaysInTheMeetingThread() {
        let first = message("<a@x>", from: pat, minutes: 0, invite: invite("M1"))
        let chat = message("<b@x>", from: me, minutes: 5, inReplyTo: "<a@x>", body: "Can we do 1pm?")
        let update = message("<c@x>", from: pat, minutes: 10, invite: invite("M1", sequence: 1))
        let threads = Threader.thread([first, chat, update])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads.first?.messages.count, 3)
    }

    // MARK: Thread rules

    private func lunchThread() -> ZirbeCore.Thread {
        let first = message("<a@x>", from: pat, minutes: 0, invite: invite("M1"))
        let chat = message("<b@x>", from: me, minutes: 5, inReplyTo: "<a@x>", body: "Can we do 1pm?")
        let update = message("<c@x>", from: pat, minutes: 10, invite: invite("M1", sequence: 1, summary: "Lunch at 1"))
        let reply = message("<d@x>", from: sam, minutes: 20,
                            invite: invite("M1", method: .reply, replyFrom: .init(name: "Sam", address: "sam@x.com", status: .accepted)))
        let later = message("<e@x>", from: pat, minutes: 30, inReplyTo: "<a@x>", body: "See you there")
        return Threader.thread([first, chat, update, reply, later]).first!
    }

    func testAnUpdateReplacesTheCardAndAnAnswerIsALine() {
        let thread = lunchThread()

        let visible = thread.conversationMessages.compactMap(\.messageID)
        XCTAssertEqual(visible, ["<b@x>", "<c@x>", "<e@x>"], "the superseded invite and the answer are not bubbles")
        XCTAssertEqual(thread.conversationMessages.first { $0.invite != nil }?.invite?.summary, "Lunch at 1")
        XCTAssertEqual(thread.messageCount, 3)

        let responses = thread.inviteResponses
        XCTAssertEqual(responses.map(\.text), ["Sam accepted"])
        let grouped = InviteResponse.byPrecedingMessage(responses, visible: thread.conversationMessages)
        XCTAssertEqual(grouped["mid:<c@x>"]?.map(\.text), ["Sam accepted"], "the line hangs under the latest bubble before it")
    }

    func testATiedSequenceKeepsTheNewerMessage() {
        let first = message("<a@x>", from: pat, minutes: 0, invite: invite("M1", sequence: 1))
        let resend = message("<b@x>", from: pat, minutes: 10, invite: invite("M1", sequence: 1, summary: "Lunch (resent)"))
        let thread = Threader.thread([first, resend]).first!
        XCTAssertEqual(thread.conversationMessages.map(\.messageID), ["<b@x>"])
    }

    func testResponseLineTexts() {
        for (status, text) in [(Invite.ParticipationStatus.accepted, "Pat accepted"), (.tentative, "Pat might attend"), (.declined, "Pat declined"), (.needsAction, "Pat replied")] {
            let response = InviteResponse(messageID: "x", attendee: .init(name: "Pat", address: "pat@x.com", status: status), date: nil)
            XCTAssertEqual(response.text, text)
        }
    }

    func testGlanceReadsTheMethod() {
        XCTAssertEqual(invite("M1").glance, "Invitation: Lunch")
        XCTAssertEqual(invite("M1", sequence: 2).glance, "Updated: Lunch")
        XCTAssertEqual(invite("M1", method: .cancel, cancelled: true).glance, "Cancelled: Lunch")
        XCTAssertEqual(invite("M1", method: .reply, replyFrom: .init(name: "Sam", address: "sam@x.com", status: .declined)).glance, "Sam declined: Lunch")
        XCTAssertEqual(invite("M1", summary: "").glance, "Invitation")
    }

    // MARK: Store

    func testTheInviteRoundTripsThroughTheStoreAndFeedsTheSnippet() async throws {
        let store = try MailStore()
        let account = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
        try await store.upsert(account)
        let header = Message(messageID: "<a@x>", uid: 1, subject: "Lunch", from: pat, to: [me], date: Date(timeIntervalSince1970: 0))
        try await store.save([header], accountID: account.id, mailboxName: "INBOX")
        try await store.rethread(accountID: account.id)

        let parsed = invite("M1", summary: "Lunch with Pat")
        try await store.storeBodies([header.id: FetchedBody(text: "", hasHTML: false, invite: parsed)])
        try await store.rethread(accountID: account.id)

        let summaries = try await store.threadSummaries(accountID: account.id)
        XCTAssertEqual(summaries.first?.preview, "Invitation: Lunch with Pat", "an invite with no text previews as the meeting")
        let thread = try await store.thread(id: XCTUnwrap(summaries.first?.id))
        XCTAssertEqual(thread?.messages.first?.invite, parsed)
        XCTAssertEqual(thread?.messages.first?.bodyText, "")
        let hits = try await store.searchThreads(accountID: account.id, query: "lunch")
        XCTAssertEqual(hits.count, 1, "the meeting's words are searchable")

        // A header re-save and rethread (the next sync) must not wipe the invite.
        try await store.save([header], accountID: account.id, mailboxName: "INBOX")
        try await store.rethread(accountID: account.id)
        let again = try await store.thread(id: XCTUnwrap(summaries.first?.id))
        XCTAssertEqual(again?.messages.first?.invite, parsed)
    }

    // MARK: Sync

    private static let outlookInvite = """
    BEGIN:VCALENDAR\r
    METHOD:REQUEST\r
    BEGIN:VEVENT\r
    UID:MEETING-1\r
    SEQUENCE:%d\r
    SUMMARY:%@\r
    DTSTART;TZID=Central Standard Time:20260915T113000\r
    DTEND;TZID=Central Standard Time:20260915T124500\r
    ORGANIZER;CN=Pat:mailto:pat@x.com\r
    ATTENDEE;PARTSTAT=NEEDS-ACTION;CN=Me:mailto:me@x.com\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    private func calendar(sequence: Int, summary: String) -> String {
        String(format: Self.outlookInvite, sequence, summary)
    }

    func testAnInviteOnlyMessageGetsABodyAndUpdatesFoldIntoOneConversation() async throws {
        let store = try MailStore()
        let server = FakeMailServer()
        let account = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
        let sync = SyncService(account: account, store: store, engine: server, sender: FakeMailSender())

        // The first invite: no plain or HTML part, only the calendar.
        await server.add(
            MailEnvelope(subject: "Lunch", from: "Pat <pat@x.com>", to: ["me@x.com"], date: Date(timeIntervalSince1970: 0), messageID: "<a@x>"),
            body: MessageBody(text: "", hasHTML: false, calendar: calendar(sequence: 0, summary: "Lunch"))
        )
        let firstSync = try await sync.syncInbox(password: "pw")
        XCTAssertEqual(firstSync.map(\.preview), ["Invitation: Lunch"])

        // The update arrives with no References header, as Outlook sends it.
        await server.add(
            MailEnvelope(subject: "Updated invitation: Lunch", from: "Pat <pat@x.com>", to: ["me@x.com"], date: Date(timeIntervalSince1970: 600), messageID: "<b@x>"),
            body: MessageBody(text: "Moved to 1pm", hasHTML: false, calendar: calendar(sequence: 1, summary: "Lunch at 1"))
        )
        let secondSync = try await sync.syncInbox(password: "pw")

        XCTAssertEqual(secondSync.count, 1, "the update joined the meeting's conversation")
        XCTAssertEqual(secondSync.first?.id, firstSync.first?.id, "under the same id")
        XCTAssertEqual(secondSync.first?.preview, "Moved to 1pm")
        let thread = try await sync.loadConversation(id: XCTUnwrap(secondSync.first?.id), password: "pw")
        XCTAssertEqual(thread?.messages.count, 2)
        XCTAssertEqual(thread?.conversationMessages.map(\.messageID), ["<b@x>"], "the first card is superseded")
        XCTAssertEqual(thread?.conversationMessages.first?.invite?.sequence, 1)
        let needing = try await store.latestMessagesNeedingBodies(accountID: account.id)
        XCTAssertTrue(needing.isEmpty, "an invite-only body is cached, not refetched every sync")
    }

    func testOpeningAConversationFollowsItIntoTheMeetingItJoined() async throws {
        let store = try MailStore()
        let server = FakeMailServer()
        let account = Account(emailAddress: "me@x.com", imapHost: "imap.x.com", smtpHost: "smtp.x.com")
        let sync = SyncService(account: account, store: store, engine: server, sender: FakeMailSender())

        // Two invites for one meeting arrive in the same sync. The backfill reads
        // only each thread's newest body, but here they are the newest of two
        // separate threads, so both are read and the rethread merges them.
        await server.add(
            MailEnvelope(subject: "Lunch", from: "Pat <pat@x.com>", to: ["me@x.com"], date: Date(timeIntervalSince1970: 0), messageID: "<a@x>"),
            body: MessageBody(text: "", hasHTML: false, calendar: calendar(sequence: 0, summary: "Lunch"))
        )
        await server.add(
            MailEnvelope(subject: "Updated: Lunch", from: "Pat <pat@x.com>", to: ["me@x.com"], date: Date(timeIntervalSince1970: 600), messageID: "<b@x>"),
            body: MessageBody(text: "", hasHTML: false, calendar: calendar(sequence: 1, summary: "Lunch"))
        )
        let summaries = try await sync.syncInbox(password: "pw")
        XCTAssertEqual(summaries.count, 1)

        // A stale id from before the merge still opens the conversation.
        let opened = try await sync.loadConversation(id: "mid:<b@x>", password: "pw")
        XCTAssertNil(opened, "the merged thread is not under the update's id")
        let current = try await sync.loadConversation(id: XCTUnwrap(summaries.first?.id), password: "pw")
        XCTAssertEqual(current?.messages.count, 2)
    }
}
