// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The new-conversation composer, presented as a sheet from the inbox, styled
// after Apple Mail's compose: a circular close and send in the header, a large
// title, then To, Cc, and Subject on hairline-divided rows with the message
// below. The subject is required (Zirbe titles a conversation by its subject, and
// a status panel reads by it), so Send stays disabled until there is a recipient,
// a subject, and a body. Threading is none: this starts a new thread.
//
// The same view also edits a saved draft: pass a `DraftEdit` to prefill the
// fields and carry the draft's `DraftContext`. Closing a composer that has
// unsaved content offers Save Draft or Discard; backgrounding saves quietly;
// sending deletes the draft it came from.

import SwiftUI
import ZirbeCore

struct ComposeView: View {
    let model: InboxModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var toText: String
    @State private var ccText: String
    @State private var bccText: String
    @State private var subject: String
    @State private var messageBody: String
    @State private var attachments: [StagedAttachment]
    /// The saved draft this composer stands for, nil until the first save. Carried
    /// across saves so an edit replaces the server copy and a send deletes it.
    @State private var draftContext: DraftContext?
    /// Snapshot of the fields as last saved (or as loaded), so a close or
    /// background only re-saves when something actually changed.
    @State private var savedSnapshot: String
    @State private var isSending = false
    @State private var isSavingDraft = false
    @State private var showCloseOptions = false
    @State private var showPicker = false
    @State private var pickerTarget: Field = .to
    /// Whether the Cc and Bcc rows are disclosed under To.
    @State private var showCcBcc = false
    @FocusState private var focus: Field?

    private enum Field { case to, cc, bcc, subject }

    /// A fresh new-conversation composer, or one prefilled from a saved draft. A
    /// saved draft carries no Bcc (the blind list is never written to the draft
    /// copy), so an edited draft opens with an empty Bcc field.
    init(model: InboxModel, editing: DraftEdit? = nil) {
        self.model = model
        let to = editing.map { Self.recipientText($0.to) } ?? ""
        let cc = editing.map { Self.recipientText($0.cc) } ?? ""
        let subject = editing?.subject ?? ""
        let body = editing?.body ?? ""
        let staged = editing?.attachments.map { StagedAttachment(attachment: $0) } ?? []
        _toText = State(initialValue: to)
        _ccText = State(initialValue: cc)
        _bccText = State(initialValue: "")
        _subject = State(initialValue: subject)
        _messageBody = State(initialValue: body)
        _attachments = State(initialValue: staged)
        _draftContext = State(initialValue: editing?.context)
        _savedSnapshot = State(initialValue: Self.snapshot(to: to, cc: cc, bcc: "", subject: subject, body: body, attachments: staged))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // The title claims the header space and is the conversation's name.
            // Left blank, it sends as a neutral default and the thread shows by
            // its participants instead.
            TextField("New Chat", text: $subject)
                .font(.largeTitle.weight(.bold))
                .focused($focus, equals: .subject)
                .padding(.horizontal)
                .padding(.bottom, 12)

            // The "To" label doubles as the Cc/Bcc disclosure; the chevron hints
            // it's tappable and flips when the rows are open.
            recipientRow("To", text: $toText, field: .to, showsDisclosure: true,
                         pick: { pickerTarget = .to; showPicker = true })
            divider
            if ccBccVisible {
                recipientRow("Cc", text: $ccText, field: .cc, showsDisclosure: false,
                             pick: { pickerTarget = .cc; showPicker = true })
                divider
                recipientRow("Bcc", text: $bccText, field: .bcc, showsDisclosure: false,
                             pick: { pickerTarget = .bcc; showPicker = true })
                divider
            }

            if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding()
            }

            // The empty conversation canvas: a new conversation reads like an
            // empty thread, composed from the bar below.
            Spacer(minLength: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            ReplyBar(
                text: $messageBody,
                attachments: $attachments,
                isSending: isSending,
                placeholder: "Message",
                canSend: hasRecipient,
                onSend: send
            )
        }
        .background(Color(.systemBackground))
        .background(ContactPicker(isPresented: $showPicker) { token in
            append(token, to: pickerTarget)
        })
        .overlay { if isSavingDraft { savingOverlay } }
        .interactiveDismissDisabled(hasContent && isDirty)
        .confirmationDialog("Save this draft?", isPresented: $showCloseOptions, titleVisibility: .visible) {
            Button("Save Draft") { saveDraftThenDismiss() }
            Button("Discard", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding mid-compose saves quietly, no prompt: the work is on
            // screen, so it should survive the app being suspended or killed.
            if phase == .background && hasContent && isDirty {
                Task { await saveDraft() }
            }
        }
        .onAppear { focus = .to }
    }

    private var savingOverlay: some View {
        ZStack {
            Color(.systemBackground).opacity(0.6).ignoresSafeArea()
            ProgressView("Saving Draft…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Append a picked recipient token to the targeted field, comma-separating it
    /// from anything already typed there.
    private func append(_ token: String, to field: Field) {
        switch field {
        case .to: toText = joined(toText, token)
        case .cc: ccText = joined(ccText, token)
        case .bcc: bccText = joined(bccText, token)
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
            circleButton("xmark", action: close)
            Spacer()
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

    /// One recipient row: a gray label, the address field, and a contacts "+".
    /// On the "To" row the label is a button that discloses Cc and Bcc, with a
    /// chevron that flips when they're open; the other rows use a plain label.
    private func recipientRow(
        _ label: String,
        text: Binding<String>,
        field: Field,
        showsDisclosure: Bool,
        pick: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if showsDisclosure {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showCcBcc.toggle() }
                } label: {
                    HStack(spacing: 2) {
                        Text(label).foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(ccBccVisible ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(ccBccVisible ? "Hide Cc and Bcc" : "Show Cc and Bcc")
            } else {
                Text(label)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            TextField(field == .to ? "name@example.com" : "Optional", text: text)
                .focused($focus, equals: field)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
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
        .padding(.horizontal)
        .padding(.vertical, 11)
    }

    private var divider: some View {
        Divider().padding(.leading)
    }

    /// Whether there's a recipient anywhere. Bcc alone is enough (an announcement
    /// that hides its list). The message bar adds the "something to send" check,
    /// and the title is optional, so this is all the composer gates on.
    private var hasRecipient: Bool {
        ![toText, ccText, bccText].allSatisfy { RecipientParsing.parse($0).isEmpty }
    }

    /// Cc and Bcc show once disclosed, or once either holds content, so collapsing
    /// can't hide a recipient already added (as Mail keeps a filled Cc visible).
    private var ccBccVisible: Bool {
        showCcBcc
            || !ccText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bccText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the composer holds anything worth keeping. An empty composer closes
    /// without a prompt; a started one offers to save.
    private var hasContent: Bool {
        ![toText, ccText, bccText, subject, messageBody]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !attachments.isEmpty
    }

    /// Whether the fields have changed since the last save (or since a draft was
    /// loaded). Keeps a no-change close or background from re-appending an
    /// identical copy.
    private var isDirty: Bool {
        Self.snapshot(to: toText, cc: ccText, bcc: bccText, subject: subject, body: messageBody, attachments: attachments) != savedSnapshot
    }

    /// Closing: offer to save when there is unsaved content, otherwise just go.
    private func close() {
        if hasContent && isDirty {
            showCloseOptions = true
        } else {
            dismiss()
        }
    }

    private func send() {
        isSending = true
        Task {
            let sent = await model.sendNew(
                to: RecipientParsing.parse(toText),
                cc: RecipientParsing.parse(ccText),
                bcc: RecipientParsing.parse(bccText),
                subject: subject,
                body: messageBody,
                attachments: attachments.map(\.attachment),
                discardingDraft: draftContext
            )
            isSending = false
            if sent { dismiss() }
        }
    }

    private func saveDraftThenDismiss() {
        isSavingDraft = true
        Task {
            await saveDraft()
            isSavingDraft = false
            dismiss()
        }
    }

    /// Save the composer to the Drafts folder, replacing the prior copy when this
    /// is an edit. On success, adopt the returned context (so a later send or
    /// re-save acts on it) and bank the snapshot so the saved state is no longer
    /// dirty.
    private func saveDraft() async {
        let saved = Self.snapshot(to: toText, cc: ccText, bcc: bccText, subject: subject, body: messageBody, attachments: attachments)
        let context = await model.saveDraft(
            to: RecipientParsing.parse(toText),
            cc: RecipientParsing.parse(ccText),
            subject: subject,
            body: messageBody,
            attachments: attachments.map(\.attachment),
            editing: draftContext
        )
        if let context {
            draftContext = context
            savedSnapshot = saved
        }
    }

    /// Format participants back into the comma-separated text the recipient fields
    /// hold, in the `Name <addr>` form `RecipientParsing` round-trips.
    private static func recipientText(_ participants: [Participant]) -> String {
        participants.map { participant in
            if let name = participant.displayName, !name.isEmpty {
                return "\(name) <\(participant.address)>"
            }
            return participant.address
        }
        .joined(separator: ", ")
    }

    /// A stable string of the editable fields, used to tell whether the composer
    /// changed since the last save. Attachments are keyed by name (their bytes
    /// don't change in place), the rest verbatim. Bcc joins the snapshot so typing
    /// a blind recipient marks the composer dirty, even though a saved draft does
    /// not retain it.
    private static func snapshot(to: String, cc: String, bcc: String, subject: String, body: String, attachments: [StagedAttachment]) -> String {
        ([to, cc, bcc, subject, body] + attachments.map(\.attachment.filename)).joined(separator: "\u{1}")
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
