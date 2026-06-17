// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The engine's output for a Web View fetch: the message's HTML plus the inline
// images it references, resolved to on-device bytes. The renderer paints a
// `cid:` image from these bytes without any network access, so an embedded logo
// or signature graphic shows even while remote content is blocked.

import Foundation

/// An HTML body fetched for the Web View, with its `cid:`-referenced inline
/// images already downloaded. Only images the HTML actually references are
/// carried, so nothing is fetched that the page won't paint.
public struct HTMLBody: Sendable, Hashable {
    public var html: String
    public var images: [InlineImagePart]

    public init(html: String, images: [InlineImagePart] = []) {
        self.html = html
        self.images = images
    }
}

/// One inline image: the Content-ID the HTML references it by, its MIME type,
/// and the decoded image bytes (transfer-decoding already applied).
public struct InlineImagePart: Sendable, Hashable {
    public var contentID: String
    public var mimeType: String
    public var data: Data

    public init(contentID: String, mimeType: String, data: Data) {
        self.contentID = contentID
        self.mimeType = mimeType
        self.data = data
    }
}
