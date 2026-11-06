// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import GRDB
@testable import ZirbeCore

extension Account {
    func insertIntoLegacySchema(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO account (id, emailAddress, displayName, imapHost, imapPort, smtpHost, smtpPort, username)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, emailAddress, displayName, imapHost, imapPort, smtpHost, smtpPort, username]
        )
    }
}
