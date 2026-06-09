// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Top level: show the connect screen until an account is connected, then the
// inbox. The store is a persistent SQLite file on the device; the password
// lives only in the InboxModel for the session and is never written to disk.

import SwiftUI
import ZirbeCore

struct RootView: View {
    @State private var model: InboxModel?

    var body: some View {
        if let model, model.isConnected {
            NavigationStack {
                InboxView(model: model)
            }
        } else {
            ConnectView { account, password in
                let store = try MailStore(path: Self.databasePath())
                let candidate = InboxModel(account: account, store: store)
                try await candidate.signIn(password: password)
                model = candidate
            }
        }
    }

    /// The on-device SQLite file, under Application Support.
    private static func databasePath() throws -> String {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return directory.appendingPathComponent("zirbe.sqlite").path
    }
}
