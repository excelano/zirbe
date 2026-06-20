// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A small on-disk cache of attachment bytes, so an image shows without a round
// trip every time its bubble scrolls into view, and so a just-sent image is
// viewable at once: the send path writes its bytes here keyed by the message's
// own id, before any Sent re-sync hands back a part section to fetch by. Lives in
// the Caches directory, which the OS may purge under pressure; nothing here is
// the only copy of anything (the real file is on the server or in the Sent mail).

import Foundation
import CryptoKit

enum AttachmentCache {
    /// The cache directory, created on first use. A subfolder of Caches so a purge
    /// or a manual clear takes the whole set at once.
    private static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = base.appendingPathComponent("ZirbeAttachments", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A filesystem-safe file name for a (message, filename) pair: the SHA-256 of
    /// the two joined, so arbitrary message ids and filenames map to a stable hex
    /// name with no path-separator or length surprises. Bytes are immutable, so the
    /// pair is a sufficient key with no versioning needed.
    private static func fileURL(messageID: String, filename: String) throws -> URL {
        let key = Data("\(messageID)\n\(filename)".utf8)
        let name = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return try directory().appendingPathComponent(name)
    }

    static func data(messageID: String, filename: String) -> Data? {
        guard let url = try? fileURL(messageID: messageID, filename: filename) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func save(_ data: Data, messageID: String, filename: String) {
        guard let url = try? fileURL(messageID: messageID, filename: filename) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
