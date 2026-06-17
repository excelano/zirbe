// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Renders an email's HTML in a sandboxed web view, shown inline as a full-tray
// takeover of a conversation when the reader switches a message to its web view.
//
// Remote content is blocked by default, the way Apple Mail handles it: a remote
// image is a tracking pixel until proven otherwise, so nothing off-device loads
// until the reader shows images. This keeps the privacy posture intact by
// default (the only thing that reaches the network is what the reader asks for).
// The HTML markup itself is loaded locally with no base URL, so only the
// resources it references are gated; a tapped link is handed to the system
// browser rather than navigating inside this view, so links keep working even
// while images are blocked.

import SwiftUI
import UIKit
import WebKit

/// A `WKWebView` that renders local HTML and, until told otherwise, blocks every
/// remote resource the HTML references. The block is a compiled content rule list
/// matching `http(s)` loads; showing images drops the rule list and reloads.
struct HTMLWebView: UIViewRepresentable {
    let html: String
    let allowRemoteContent: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        // Email HTML is authored for a light canvas: senders set dark text against
        // an assumed white background and rarely supply one of their own. Render on
        // an opaque white canvas in a forced-light context (the way Apple Mail
        // does) so a plain text-as-HTML mail can't come out dark-on-dark in Dark
        // Mode, and the sender's own dark Web View backdrop never shows through.
        // The document declares color-scheme: light too (see prepared()).
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.overrideUserInterfaceStyle = .light
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(html: html, allowRemoteContent: allowRemoteContent, in: webView)
    }

    /// Tracks the last render so an unrelated SwiftUI update doesn't reload the
    /// page (and lose the reader's scroll position) when nothing it cares about
    /// changed. Only a new body or a flip of the remote-content gate reloads.
    /// Also the navigation delegate, routing tapped links out to the browser.
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var lastHTML: String?
        private var lastAllowRemote: Bool?

        /// The rule that blocks every remote load. Local `loadHTMLString` content
        /// has no scheme and is unaffected; only `http(s)` subresources match.
        private static let blockRemoteRuleList = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
        """

        func render(html: String, allowRemoteContent: Bool, in webView: WKWebView) {
            guard lastHTML != html || lastAllowRemote != allowRemoteContent else { return }
            lastHTML = html
            lastAllowRemote = allowRemoteContent

            let document = Self.prepared(html)
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()

            if allowRemoteContent {
                webView.loadHTMLString(document, baseURL: nil)
            } else {
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "zirbe-block-remote",
                    encodedContentRuleList: Self.blockRemoteRuleList
                ) { ruleList, _ in
                    if let ruleList { controller.add(ruleList) }
                    // Load whether or not compilation succeeded: failing closed
                    // would show a blank page, so on the rare compile error we
                    // render the mail rather than nothing.
                    webView.loadHTMLString(document, baseURL: nil)
                }
            }
        }

        /// Email HTML often omits a mobile viewport, so WKWebView lays it out at a
        /// desktop width and it shows zoomed out and overflowing. Inject a
        /// device-width viewport (only when the mail doesn't set its own, so
        /// responsive emails keep theirs) plus a little CSS so wide images shrink
        /// to fit the tray rather than spilling past it.
        static func prepared(_ html: String) -> String {
            let hasViewport = html.range(
                of: "name=[\"']?viewport", options: [.regularExpression, .caseInsensitive]
            ) != nil
            let head = (hasViewport ? "" : #"<meta name="viewport" content="width=device-width, initial-scale=1">"#)
                // Render light: declare the page light-only so WebKit won't auto-
                // darken it and the sender's own prefers-color-scheme:dark rules stay
                // dormant, and default the canvas to white so a mail that sets text
                // color but no background reads as dark-on-white, not dark-on-dark. A
                // mail that supplies its own background still wins (no !important).
                + #"<meta name="color-scheme" content="light">"#
                + "<style>img,video{max-width:100%;height:auto;}html,body{background:#fff;}body{margin:0;-webkit-text-size-adjust:100%;}</style>"

            // Slip the head into the document where one belongs, or wrap a bare
            // fragment in a minimal document.
            if let r = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                return html.replacingCharacters(in: r, with: String(html[r]) + head)
            }
            if let r = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                return html.replacingCharacters(in: r, with: String(html[r]) + "<head>\(head)</head>")
            }
            return "<!DOCTYPE html><html><head>\(head)</head><body>\(html)</body></html>"
        }

        /// The smallest the fit-to-width zoom is allowed to shrink a page. Below
        /// this, the text would be too small to read, so the page stops scaling and
        /// its over-wide content scrolls sideways instead. Tunable; dialed in on
        /// device (lower = fits more across but smaller text; higher = bigger text
        /// but more horizontal scroll on very wide mail).
        /// Once the page is laid out, zoom it to fit when its content is wider than
        /// the tray. The viewport injection handles emails that simply lacked one,
        /// but a fixed-width layout (a hard-coded wide table, common in order and
        /// newsletter mail like AliExpress receipts) still overflows. Measuring the
        /// real content width and rewriting the viewport to lay out at that width
        /// and scale down zooms the whole page to fit without reflowing or
        /// distorting its layout, so it never needs sideways scrolling.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let js = """
            (function() {
              var d = document.documentElement, b = document.body;
              var w = Math.max(d.scrollWidth, d.offsetWidth, b ? b.scrollWidth : 0, b ? b.offsetWidth : 0);
              var vw = window.innerWidth;
              if (w > vw + 1) {
                var m = document.querySelector('meta[name=viewport]');
                if (!m) { m = document.createElement('meta'); m.name = 'viewport'; document.head.appendChild(m); }
                m.setAttribute('content', 'width=' + w + ', initial-scale=' + (vw / w));
              }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        /// Render the local HTML in place, but send a tapped link out to the
        /// system browser (Safari, Mail for `mailto:`, the dialer for `tel:`)
        /// rather than navigating inside this sandboxed view. The first
        /// `loadHTMLString` is a `.other` navigation and is allowed through.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
