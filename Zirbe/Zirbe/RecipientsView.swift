// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Who a reply will go to, and the gesture to drop someone, the way a group chat
// lets you remove a member. The default is reply-all derived from the thread's
// latest message; toggling a person off adds their address to the removed set
// the conversation passes to `sendReply(removing:)`. Removing is reversible
// here: a removed person shows struck through with an undo, so a misfire is one
// tap to recover.

import SwiftUI
import ZirbeCore

struct RecipientsView: View {
    let to: [Participant]
    let cc: [Participant]
    @Binding var removedAddresses: Set<String>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !to.isEmpty {
                    Section("To") {
                        ForEach(to) { row($0) }
                    }
                }
                if !cc.isEmpty {
                    Section("Cc") {
                        ForEach(cc) { row($0) }
                    }
                }
            }
            .navigationTitle("Recipients")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ participant: Participant) -> some View {
        let isRemoved = removedAddresses.contains(participant.address)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(participant.label)
                    .strikethrough(isRemoved)
                    .foregroundStyle(isRemoved ? .secondary : .primary)
                if participant.displayName != nil {
                    Text(participant.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .strikethrough(isRemoved)
                }
            }
            Spacer()
            Button {
                toggle(participant.address)
            } label: {
                Image(systemName: isRemoved ? "arrow.uturn.backward.circle" : "minus.circle.fill")
                    .foregroundStyle(isRemoved ? Color.accentColor : .red)
            }
            .buttonStyle(.borderless)
        }
    }

    private func toggle(_ address: String) {
        if removedAddresses.contains(address) {
            removedAddresses.remove(address)
        } else {
            removedAddresses.insert(address)
        }
    }
}
