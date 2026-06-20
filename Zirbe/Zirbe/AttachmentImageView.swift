// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// An image attachment shown inline in its bubble, the way a photo reads in a
// chat rather than as a filename to tap. It loads the bytes through the model
// (cache first, then a fetch), downsamples to a thumbnail for display, and opens
// the full-resolution image in QuickLook on tap. If the bytes can't be had (a
// purely local attachment never cached, or a failed fetch) it falls back to the
// plain chip so the file is still named and reachable.

import SwiftUI
import ImageIO
import QuickLook
import UIKit
import ZirbeCore

struct InlineAttachmentImage: View {
    let model: InboxModel
    let messageID: String
    let attachment: MessageAttachment
    let isOwn: Bool

    /// The downsampled image for display; nil until loaded.
    @State private var thumbnail: UIImage?
    /// The full bytes, held so a tap can open the original without re-fetching.
    @State private var fullData: Data?
    /// Set once a load fails, switching to the chip fallback.
    @State private var failed = false
    /// The temp file the full image was written to; setting it presents QuickLook.
    @State private var previewURL: URL?

    private let maxWidth: CGFloat = 240
    private let maxHeight: CGFloat = 320

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture(perform: openFull)
                    .accessibilityLabel("Image, \(attachment.filename)")
                    .accessibilityAddTraits(.isButton)
            } else if failed {
                AttachmentChip(model: model, messageID: messageID, attachment: attachment, isOwn: isOwn)
            } else {
                placeholder
            }
        }
        .task { await load() }
        .quickLookPreview($previewURL)
    }

    /// A sized stand-in while the bytes load, tinted to sit on its bubble.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isOwn ? AnyShapeStyle(Color.white.opacity(0.18)) : AnyShapeStyle(Color(.tertiarySystemFill)))
            .frame(width: 180, height: 130)
            .overlay { ProgressView() }
    }

    /// Load the bytes (cache or fetch) and downsample to a display thumbnail. A
    /// missing or undecodable image drops to the chip fallback.
    private func load() async {
        guard thumbnail == nil, !failed else { return }
        guard let data = await model.imageData(messageID: messageID, attachment: attachment) else {
            failed = true
            return
        }
        fullData = data
        if let image = ImageDownsampler.thumbnail(from: data, maxPixelSize: 700) {
            thumbnail = image
        } else {
            failed = true
        }
    }

    /// Write the full bytes to a temp file named for the attachment and open them
    /// in QuickLook, where the image can be zoomed, saved, and shared.
    private func openFull() {
        guard let fullData else { return }
        previewURL = try? AttachmentFile.write(fullData, filename: attachment.filename, mimeType: attachment.mimeType)
    }
}

/// Downsamples encoded image bytes to a thumbnail at a bounded pixel size, via
/// ImageIO so a large photo never fully decodes into memory just to be shown
/// small. Honors the image's orientation.
enum ImageDownsampler {
    static func thumbnail(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
