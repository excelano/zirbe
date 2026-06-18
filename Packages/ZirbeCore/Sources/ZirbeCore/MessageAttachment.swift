// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A message's user-facing attachment, the domain view the conversation bubble
// renders as a chip. Carries only what the chip shows: a display name and the
// MIME type an icon is chosen from. The inline parts the body references
// (signature logos, embedded images) are already dropped upstream by Klartext's
// cid join, so every value here is a real attachment.

import Foundation

/// One attachment shown on a message. `filename` is always a display string (a
/// type label stands in when the part carried no name), so a chip never reads
/// blank. Bytes are not held; this is metadata, fetched free with the body.
public struct MessageAttachment: Sendable, Hashable, Codable {
    public var filename: String
    public var mimeType: String

    public init(filename: String, mimeType: String) {
        self.filename = filename
        self.mimeType = mimeType
    }
}
