// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import Foundation

public struct MessageMedia: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let audio = MessageMedia(rawValue: 1 << 0)
    public static let video = MessageMedia(rawValue: 1 << 1)

    public init(mimeTypes: some Sequence<String>) {
        self = []
        for type in mimeTypes.lazy.map({ $0.lowercased() }) {
            if type.hasPrefix("audio/") { insert(.audio) }
            if type.hasPrefix("video/") { insert(.video) }
        }
    }
}
