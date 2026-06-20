// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Send-side attachments shared by the new-conversation composer and the inline
// reply bar: the attach button that offers the photo library, the camera, and
// the Files browser; the tray of removable chips for what's been picked; and the
// loaders that read each source into a ZirbeCore DraftAttachment. The chips match
// the received-attachment chip in ConversationView so a file looks the same going
// out as coming in.

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import ZirbeCore

/// A picked file held in the composer with a stable identity, so the tray can
/// list it and remove it. Wraps the domain value the send path actually takes.
struct StagedAttachment: Identifiable {
    let id = UUID()
    let attachment: DraftAttachment
}

/// The SF Symbol for a MIME type, shared by the staged chips here and the
/// received-attachment chip in ConversationView so the two stay in step.
enum AttachmentSymbol {
    static func symbol(for mimeType: String) -> String {
        let type = mimeType.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.hasPrefix("text/") { return "doc.text" }
        if type.contains("word") || type.contains("wordprocessing") { return "doc.text" }
        if type.contains("spreadsheet") || type.contains("excel") || type.contains("csv") { return "tablecells" }
        if type.contains("presentation") || type.contains("powerpoint") { return "rectangle.on.rectangle" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.hasPrefix("video/") { return "film" }
        return "paperclip"
    }
}

/// The paperclip affordance: a circular button whose menu offers the photo
/// library, the camera (only where there is one, so the simulator shows two
/// choices), and Files. Each source loads into the bound staging list.
struct AttachButton: View {
    @Binding var attachments: [StagedAttachment]

    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        Menu {
            Button {
                showPhotos = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }
            if CameraPicker.isAvailable {
                Button {
                    showCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
            Button {
                showFiles = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color(.secondarySystemFill), in: Circle())
        }
        .accessibilityLabel("Add attachment")
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await addPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls {
                    if let draft = AttachmentLoader.draft(fromFile: url) { append(draft) }
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if let draft = AttachmentLoader.draft(from: image) { append(draft) }
            }
            .ignoresSafeArea()
        }
    }

    /// Load each picked photo off the main actor, then append on the main actor
    /// and clear the picker selection so the next pick fires `onChange` again.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        var loaded: [DraftAttachment] = []
        for item in items {
            if let draft = await AttachmentLoader.draft(from: item) { loaded.append(draft) }
        }
        await MainActor.run {
            for draft in loaded { append(draft) }
            photoItems = []
        }
    }

    private func append(_ draft: DraftAttachment) {
        attachments.append(StagedAttachment(attachment: draft))
    }
}

/// The horizontal strip of picked-file chips above the composer, each removable
/// with its x. Renders nothing when empty so the row collapses.
struct AttachmentTray: View {
    @Binding var attachments: [StagedAttachment]

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { staged in
                        HStack(spacing: 5) {
                            Image(systemName: AttachmentSymbol.symbol(for: staged.attachment.mimeType))
                            Text(staged.attachment.filename)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                attachments.removeAll { $0.id == staged.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(staged.attachment.filename)")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                }
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Reads each attachment source into a DraftAttachment: a photo-library item, a
/// security-scoped file URL, or a freshly captured image. Filenames the library
/// and camera don't supply are synthesized; a missing MIME type falls back to a
/// generic binary type so the file still sends.
enum AttachmentLoader {
    static func draft(from item: PhotosPickerItem) async -> DraftAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let ext = type?.preferredFilenameExtension ?? "dat"
        return DraftAttachment(filename: "IMG-\(token()).\(ext)", mimeType: mime, data: data)
    }

    static func draft(fromFile url: URL) -> DraftAttachment? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return DraftAttachment(filename: url.lastPathComponent, mimeType: mime, data: data)
    }

    static func draft(from image: UIImage) -> DraftAttachment? {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return nil }
        return DraftAttachment(filename: "Photo-\(token()).jpg", mimeType: "image/jpeg", data: data)
    }

    private static func token() -> String {
        String(UUID().uuidString.prefix(6))
    }
}

/// The system camera, wrapped for SwiftUI. Presented only where a camera exists;
/// hands back the captured image and dismisses on capture or cancel.
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
