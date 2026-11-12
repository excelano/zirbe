// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import SwiftUI
import AVFoundation
import CoreTransferable
import UniformTypeIdentifiers
import UIKit
import ZirbeCore

nonisolated enum VideoExport {
    static let byteBudget: Int64 = 14_000_000

    enum Failure: Error {
        case tooLarge
    }

    private static let presets = [
        AVAssetExportPreset1280x720,
        AVAssetExportPreset960x540,
        AVAssetExportPreset640x480,
        AVAssetExportPresetMediumQuality,
        AVAssetExportPresetLowQuality,
    ]

    @concurrent static func compressed(_ source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.outputFileType = .mp4
            if let estimate = try? await session.estimatedOutputFileLengthInBytes, estimate > byteBudget {
                continue
            }
            let output = temporaryURL(extension: "mp4")
            try await session.export(to: output, as: .mp4)
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? Int.max
            if Int64(size) <= byteBudget { return output }
            try? FileManager.default.removeItem(at: output)
        }
        throw Failure.tooLarge
    }

    static func audioTrack(of video: URL) async throws -> URL? {
        let asset = AVURLAsset(url: video)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let output = temporaryURL(extension: "m4a")
        try await session.export(to: output, as: .m4a)
        return output
    }

    static func poster(of video: URL) async -> (image: UIImage, duration: TimeInterval)? {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 700, height: 700)
        guard let frame = try? await generator.image(at: .zero),
              let duration = try? await asset.load(.duration) else { return nil }
        return (UIImage(cgImage: frame.image), duration.seconds)
    }

    static func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "video-\(UUID().uuidString).\(ext)")
    }
}

struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = VideoExport.temporaryURL(extension: received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

struct VideoCamera: UIViewControllerRepresentable {
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
            && (UIImagePickerController.availableMediaTypes(for: .camera) ?? []).contains(UTType.movie.identifier)
    }

    let onCapture: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        if UIImagePickerController.isCameraDeviceAvailable(.front) {
            picker.cameraDevice = .front
        }
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 180
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VideoCamera

        init(_ parent: VideoCamera) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let recorded = info[.mediaURL] as? URL {
                let copy = VideoExport.temporaryURL(extension: recorded.pathExtension)
                if (try? FileManager.default.copyItem(at: recorded, to: copy)) != nil {
                    parent.onCapture(copy)
                }
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

struct InlineAttachmentVideo: View {
    let model: InboxModel
    let messageID: String
    let attachment: MessageAttachment
    let isOwn: Bool
    let transcript: String?
    let transcribes: Bool

    @State private var poster: UIImage?
    @State private var duration: TimeInterval = 0
    @State private var fileURL: URL?
    @State private var failed = false
    @State private var previewURL: URL?
    @State private var heard: String?
    @State private var isTranscribing = false

    var body: some View {
        if failed {
            AttachmentChip(model: model, messageID: messageID, attachment: attachment, isOwn: isOwn)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                frame
                transcriptText
            }
            .task { await load() }
            .task {
                guard transcribes, transcript == nil else { return }
                isTranscribing = true
                heard = await TranscriptionQueue.transcribe(attachment, of: messageID, in: model)
                isTranscribing = false
            }
            .quickLook($previewURL)
        }
    }

    @ViewBuilder
    private var frame: some View {
        if let poster {
            Image(uiImage: poster)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240, maxHeight: 320)
                .overlay {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.35))
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(VoiceRecorder.clock(duration))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { previewURL = fileURL }
                .accessibilityLabel("Video message, \(VoiceRecorder.clock(duration))")
                .accessibilityAddTraits(.isButton)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isOwn ? AnyShapeStyle(Color.white.opacity(0.18)) : AnyShapeStyle(Color(.tertiarySystemFill)))
                .frame(width: 180, height: 130)
                .overlay { ProgressView() }
        }
    }

    @ViewBuilder
    private var transcriptText: some View {
        if let words = transcript ?? heard, !words.isEmpty {
            Text(words)
                .foregroundStyle(isOwn ? .white : .primary)
                .fixedSize(horizontal: false, vertical: true)
        } else if isTranscribing {
            Text("Transcribing…")
                .font(.caption)
                .foregroundStyle(isOwn ? Color.white.opacity(0.85) : .secondary)
        }
    }

    private func load() async {
        guard poster == nil, !failed else { return }
        guard let data = await model.cachedAttachmentData(messageID: messageID, attachment: attachment),
              let url = try? AttachmentFile.write(data, filename: attachment.filename, mimeType: attachment.mimeType),
              let loaded = await VideoExport.poster(of: url) else {
            failed = true
            return
        }
        fileURL = url
        poster = loaded.image
        duration = loaded.duration
    }
}
