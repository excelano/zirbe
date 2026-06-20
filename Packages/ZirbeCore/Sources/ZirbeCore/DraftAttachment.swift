// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A file the user has picked to send, in ZirbeCore's own vocabulary: a name, a
// MIME type, and the bytes, already read into memory. The app stages these from
// the photo library, the camera, or the Files browser and hands them to the send
// path; ZirbeCore maps them to the transport's OutgoingAttachment internally, so
// the app never reaches into the ZirbeMail layer.
//
// This is the send-side counterpart to MessageAttachment (the received chip,
// which carries an IMAP part section instead of bytes), mirroring how the domain
// keeps its own Participant beside the transport's address type.

import Foundation

public struct DraftAttachment: Sendable, Hashable {
    /// The name shown on the chip and written into the message part.
    public var filename: String
    /// The content type, e.g. `image/jpeg` or `application/pdf`.
    public var mimeType: String
    /// The file's bytes, read in full when the user picked it.
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}
