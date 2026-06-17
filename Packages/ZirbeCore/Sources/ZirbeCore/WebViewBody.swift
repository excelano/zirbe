// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// The domain-layer view of a message fetched for the Web View: its HTML and the
// inline images the markup references, resolved to on-device bytes. The UI hands
// these to the shared KlartextUI renderer, which paints a `cid:` image from the
// bytes with no network access. This is the ZirbeCore-owned shape the app sees;
// the transport's equivalent (ZirbeMail.HTMLBody) never crosses into the app.

import Foundation

/// A message's HTML body plus its `cid:`-referenced inline images, ready to
/// render. `inlineImages` is empty for plain HTML with no embedded graphics.
public struct WebViewBody: Sendable, Hashable {
    public var html: String
    public var inlineImages: [InlineImage]

    public init(html: String, inlineImages: [InlineImage] = []) {
        self.html = html
        self.inlineImages = inlineImages
    }
}

/// One inline image: the Content-ID the HTML references it by, its MIME type,
/// and the decoded image bytes.
public struct InlineImage: Sendable, Hashable {
    public var contentID: String
    public var mimeType: String
    public var data: Data

    public init(contentID: String, mimeType: String, data: Data) {
        self.contentID = contentID
        self.mimeType = mimeType
        self.data = data
    }
}
