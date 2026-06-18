// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The forward composer, presented as a sheet from a conversation. It reuses the
// new-conversation compose chrome (a circular close and send, labeled recipient
// rows) but adds two things a forward needs: an optional note above the
// forwarded message, and a read-only summary of what's being sent on — the
// original's sender and its attachments — so the user can see the payload before
// it goes. A forward starts a new conversation under a `Fwd:` subject, so Send
// needs a recipient and a subject but not a note (forwarding silently is fine).

import SwiftUI
import ZirbeCore

struct ForwardView: View {
    let model: InboxModel
    let message: Message
    let thread: ZirbeCore.Thread
    @Environment(\.dismiss) private var dismiss

    @State private var toText = ""
    @State private var ccText = ""
    @State private var subject: String
    @State private var note = ""
    @State private var isSending = false
    @State private var showPicker = false
    @State private var pickerTarget: Field = .to
    @FocusState private var focus: Field?

    private enum Field { case to, cc, subject, note }

    init(model: InboxModel, message: Message, thread: ZirbeCore.Thread) {
        self.model = model
        self.message = message
        self.thread = thread
        _subject = State(initialValue: ReplyBuilder.forwardSubject(for: thread))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text("Forward")
                .font(.largeTitle.weight(.bold))
                .padding(.horizontal)
                .padding(.bottom, 12)

            field("To:", placeholder: "name@example.com", text: $toText, field: .to, email: true,
                  pick: { pickerTarget = .to; showPicker = true })
            divider
            field("Cc:", placeholder: "Optional", text: $ccText, field: .cc, email: true,
                  pick: { pickerTarget = .cc; showPicker = true })
            divider
            field("Subject:", placeholder: "Subject", text: $subject, field: .subject)
            divider

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding()
            }

            TextField("Add a note", text: $note, axis: .vertical)
                .focused($focus, equals: .note)
                .padding()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { focus = .note }

            forwardedSummary
        }
        .background(Color(.systemBackground))
        .background(ContactPicker(isPresented: $showPicker) { token in
            append(token, to: pickerTarget)
        })
        .onAppear { focus = .to }
    }

    /// A read-only card showing what rides along: who the message is from and the
    /// files attached. Sits below the note so the user sees the payload before
    /// sending. The body text isn't repeated here — it goes whole into the sent
    /// mail; this is just the at-a-glance manifest.
    private var forwardedSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.right")
                    .foregroundStyle(.secondary)
                Text("Forwarding \(message.from?.label ?? "a message")")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.caption)
                    Text(attachment.filename)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
    }

    /// Append a picked recipient token to the targeted field, comma-separating it
    /// from anything already typed there.
    private func append(_ token: String, to field: Field) {
        switch field {
        case .to: toText = joined(toText, token)
        case .cc: ccText = joined(ccText, token)
        default: break
        }
    }

    private func joined(_ existing: String, _ token: String) -> String {
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return token }
        return trimmed.hasSuffix(",") ? "\(trimmed) \(token)" : "\(trimmed), \(token)"
    }

    private var header: some View {
        HStack {
            circleButton("xmark", action: dismiss.callAsFunction)
            Spacer()
            if isSending {
                ProgressView().frame(width: 42, height: 42)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(canSend ? .white : Color.secondary)
                        .frame(width: 42, height: 42)
                        .background(canSend ? Color.accentColor : Color(.secondarySystemFill), in: Circle())
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding()
    }

    private func circleButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42, height: 42)
                .background(Color(.secondarySystemFill), in: Circle())
        }
    }

    /// One labeled input row, matching the new-conversation composer: a gray
    /// `Label:` prefix and the field, with an optional contacts-pick button.
    private func field(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        field: Field,
        email: Bool = false,
        pick: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            TextField(placeholder, text: text)
                .focused($focus, equals: field)
                .textInputAutocapitalization(email ? .never : .sentences)
                .autocorrectionDisabled(email)
                .keyboardType(email ? .emailAddress : .default)
            if let pick {
                Button(action: pick) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add from Contacts")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 11)
    }

    private var divider: some View {
        Divider().padding(.leading)
    }

    private var canSend: Bool {
        !RecipientParsing.parse(toText).isEmpty
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        isSending = true
        Task {
            let sent = await model.sendForward(
                message,
                in: thread,
                to: RecipientParsing.parse(toText),
                cc: RecipientParsing.parse(ccText),
                note: note
            )
            isSending = false
            if sent { dismiss() }
        }
    }
}
