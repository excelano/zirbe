// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The address-book type-ahead for a recipient field, as one self-contained view
// dropped beneath the field it serves. Give it the field's text binding and
// whether that field is focused; it searches the on-device Contacts store as the
// text changes, lists the matches while the field is focused, and completes the
// in-progress fragment when a match is tapped. Owning its own suggestion state
// (and the generation guard that keeps a slow earlier lookup from overwriting a
// newer one) means every recipient field — a new conversation, a forward — gets
// the same behavior by attaching this, with no per-field plumbing to repeat. The
// lookup is local and display-only, the same Contacts access used for avatars;
// nothing leaves the device.

import SwiftUI
import ZirbeCore

struct RecipientSuggestions: View {
    /// The recipient field's text; completing a suggestion rewrites the trailing
    /// fragment in place.
    @Binding var text: String
    /// Whether the field this serves is focused. Suggestions show only while it is,
    /// and refresh when focus arrives on a field that already holds a fragment.
    var isFocused: Bool

    @State private var suggestions: [ContactSuggestion] = []
    /// Bumped on each search so a slower earlier lookup can't overwrite a newer
    /// one's results.
    @State private var generation = 0

    var body: some View {
        Group {
            if isFocused, !suggestions.isEmpty {
                list
            }
        }
        .onChange(of: text) { _, newValue in search(newValue) }
        .onChange(of: isFocused) { _, focused in
            if focused { search(text) } else { suggestions = [] }
        }
    }

    /// The matches beneath the field: tap one to fill it in. Each shows the
    /// contact's avatar, name, and the matched email.
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button { choose(suggestion) } label: {
                    HStack(spacing: 10) {
                        SenderAvatar(participant: suggestion.participant, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            if !suggestion.name.isEmpty {
                                Text(suggestion.name).foregroundStyle(.primary)
                            }
                            Text(suggestion.email)
                                .font(suggestion.name.isEmpty ? .body : .subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if suggestion.id != suggestions.last?.id {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    /// Search the address book for the fragment currently being typed, dropping a
    /// stale earlier result so the newest keystroke's matches win. Clears the list
    /// when the fragment is empty.
    private func search(_ text: String) {
        let fragment = RecipientDraftText.currentFragment(text)
        guard !fragment.isEmpty else { suggestions = []; return }
        generation += 1
        let current = generation
        Task {
            let matches = await ContactSearchService.shared.search(fragment)
            if current == generation { suggestions = matches }
        }
    }

    /// Fill the chosen contact into the field, replacing the in-progress fragment,
    /// and clear the list.
    private func choose(_ suggestion: ContactSuggestion) {
        text = RecipientDraftText.completing(text, with: suggestion.token)
        suggestions = []
    }
}
