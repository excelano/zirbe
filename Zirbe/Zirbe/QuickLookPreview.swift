// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// A full QuickLook preview. SwiftUI's built-in `.quickLookPreview` modifier shows
// the file but hides QuickLook's toolbar, so there's no way to get the attachment
// out of the app. This wraps QLPreviewController in a navigation controller, which
// restores QuickLook's native Share / Save to Files action alongside a Done
// button. Present it with `.quickLook($url)`, the same shape as the built-in.

import SwiftUI
import UIKit
import QuickLook

extension View {
    /// Present `url` in a full QuickLook preview (with Share / Save to Files) while
    /// it's non-nil; clearing it on dismiss.
    func quickLook(_ url: Binding<URL?>) -> some View {
        fullScreenCover(isPresented: Binding(
            get: { url.wrappedValue != nil },
            set: { if !$0 { url.wrappedValue = nil } }
        )) {
            if let value = url.wrappedValue {
                QuickLookPreview(url: value) { url.wrappedValue = nil }
                    .ignoresSafeArea()
            }
        }
    }
}

/// QLPreviewController as the root of a navigation controller, so its native
/// toolbar (the Share action, which offers Save to Files, AirDrop, and the rest)
/// is shown, with an added Done button to dismiss.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: context.coordinator,
            action: #selector(Coordinator.done)
        )
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let parent: QuickLookPreview

        init(_ parent: QuickLookPreview) { self.parent = parent }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            parent.url as NSURL
        }

        @objc func done() { parent.onDismiss() }
    }
}
