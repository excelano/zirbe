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
/// blank. Bytes are not held; this is metadata, fetched free with the body, plus
/// the `partID` that lets the bytes be fetched on demand when the chip is tapped.
public struct MessageAttachment: Sendable, Hashable, Codable {
    public var filename: String
    public var mimeType: String
    /// The IMAP body section of this part (e.g. "2" or "3.1"), used to fetch its
    /// bytes when opened. Empty for an attachment cached before part ids were
    /// tracked, which then can't be opened until its body is re-fetched.
    public var partID: String

    public init(filename: String, mimeType: String, partID: String) {
        self.filename = filename
        self.mimeType = mimeType
        self.partID = partID
    }

    /// Decodes tolerantly: a row written before `partID` existed has no such key,
    /// and reads back with an empty one rather than failing the whole decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filename = try container.decode(String.self, forKey: .filename)
        mimeType = try container.decode(String.self, forKey: .mimeType)
        partID = try container.decodeIfPresent(String.self, forKey: .partID) ?? ""
    }
}
