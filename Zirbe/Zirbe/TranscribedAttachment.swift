// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import SwiftUI
import ZirbeCore

struct TranscribedAttachment<Media: View>: View {
    let model: InboxModel
    let messageID: String
    let attachment: MessageAttachment
    let isOwn: Bool
    let transcript: String?
    let transcribes: Bool
    let waitingColor: Color
    @ViewBuilder let media: Media

    @State private var heard: String?
    @State private var isTranscribing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            media
            if let words = transcript ?? heard, !words.isEmpty {
                Text(words)
                    .foregroundStyle(isOwn ? .white : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isTranscribing {
                Text("Transcribing…")
                    .font(.caption)
                    .foregroundStyle(waitingColor)
            }
        }
        .task {
            guard transcribes, transcript == nil else { return }
            isTranscribing = true
            heard = await TranscriptionQueue.transcribe(attachment, of: messageID, in: model)
            isTranscribing = false
        }
    }
}
