// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The new-conversation composer, presented as a sheet from the inbox, styled
// after Apple Mail's compose: a circular close and send in the header, a large
// title, then To, Cc, and Subject on hairline-divided rows with the message
// below. The subject is required (Zirbe titles a conversation by its subject, and
// a status panel reads by it), so Send stays disabled until there is a recipient,
// a subject, and a body. Threading is none: this starts a new thread.

import SwiftUI
import ZirbeCore

struct ComposeView: View {
    let model: InboxModel
    @Environment(\.dismiss) private var dismiss

    @State private var toText = ""
    @State private var ccText = ""
    @State private var subject = ""
    @State private var messageBody = ""
    @State private var attachments: [StagedAttachment] = []
    @State private var isSending = false
    @State private var showPicker = false
    @State private var pickerTarget: Field = .to
    @FocusState private var focus: Field?

    private enum Field { case to, cc, subject, body }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text("New Conversation")
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

            HStack(spacing: 8) {
                AttachButton(attachments: $attachments)
                AttachmentTray(attachments: $attachments)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            divider

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding()
            }

            TextField("Message", text: $messageBody, axis: .vertical)
                .focused($focus, equals: .body)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { focus = .body }
        }
        .background(Color(.systemBackground))
        .background(ContactPicker(isPresented: $showPicker) { token in
            append(token, to: pickerTarget)
        })
        .onAppear { focus = .to }
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

    /// One labeled input row: a gray `Label:` prefix and the field, the way Mail's
    /// compose header reads. `email` rows turn off autocapitalization and
    /// correction and use the email keyboard; the subject takes normal text.
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
            && (!messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func send() {
        isSending = true
        Task {
            let sent = await model.sendNew(
                to: RecipientParsing.parse(toText),
                cc: RecipientParsing.parse(ccText),
                subject: subject,
                body: messageBody,
                attachments: attachments.map(\.attachment)
            )
            isSending = false
            if sent { dismiss() }
        }
    }
}

/// Turns a recipient text field into participants. Splits on commas and
/// semicolons, accepts both a bare address and the `Name <addr>` form, and drops
/// anything without an `@`. Deliberately forgiving: validation happens at send,
/// where an empty recipient list is rejected with a clear message.
enum RecipientParsing {
    static func parse(_ text: String) -> [Participant] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .compactMap { participant(from: $0) }
    }

    private static func participant(from token: String) -> Participant? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let open = trimmed.firstIndex(of: "<"), let close = trimmed.firstIndex(of: ">"), open < close {
            let address = String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            let name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            guard address.contains("@") else { return nil }
            return Participant(address: address, displayName: name.isEmpty ? nil : name)
        }

        guard trimmed.contains("@") else { return nil }
        return Participant(address: trimmed)
    }
}
