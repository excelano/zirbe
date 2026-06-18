import XCTest
import SwiftMail
@testable import ZirbeMail

/// The engine's attachment extraction: pulling the right parts off a message's
/// MIME structure and letting Klartext's cid join decide which are real
/// attachments. The join itself is Klartext's (tested there); these cover the
/// transport side — what we feed it and what we keep.
final class AttachmentClassificationTests: XCTestCase {

    private func part(
        _ section: String,
        _ contentType: String,
        disposition: String? = nil,
        filename: String? = nil,
        contentId: String? = nil
    ) -> MessagePart {
        MessagePart(
            sectionString: section,
            contentType: contentType,
            disposition: disposition,
            filename: filename,
            contentId: contentId
        )
    }

    // MARK: - Input extraction

    func testInputsExcludeBodyAndMultipartParts() {
        let plain = part("1", "text/plain")
        let html = part("2", "text/html")
        let parts = [
            part("0", "multipart/mixed"),
            plain,
            html,
            part("3", "application/pdf", disposition: "attachment", filename: "report.pdf"),
        ]
        let inputs = MailEngine.attachmentInputs(in: parts, excluding: [plain.section, html.section])
        XCTAssertEqual(inputs.map(\.filename), ["report.pdf"])
        XCTAssertEqual(inputs.first?.mimeType, "application/pdf")
    }

    func testInputStripsMIMEParameters() {
        let parts = [part("1", "image/png; name=logo.png", filename: "logo.png", contentId: "<logo@x>")]
        let inputs = MailEngine.attachmentInputs(in: parts, excluding: [])
        XCTAssertEqual(inputs.first?.mimeType, "image/png")
        XCTAssertEqual(inputs.first?.contentID, "<logo@x>")
    }

    func testDispositionMapping() {
        XCTAssertEqual(MailEngine.disposition("inline"), .inline)
        XCTAssertEqual(MailEngine.disposition("ATTACHMENT"), .attachment)
        XCTAssertEqual(MailEngine.disposition(nil), .unknown)
        XCTAssertEqual(MailEngine.disposition("form-data"), .unknown)
    }

    // MARK: - User-facing classification (the cid join)

    func testInlineLogoReferencedByHTMLIsDropped() {
        // A signature logo the HTML paints via `cid:` is inline, not a real
        // attachment; the PDF and an unreferenced image are both kept.
        let plain = part("1", "text/plain")
        let html = part("2", "text/html")
        let parts = [
            plain, html,
            part("3", "image/png", disposition: "inline", filename: "logo.png", contentId: "<logo@x>"),
            part("4", "image/jpeg", disposition: "attachment", filename: "photo.jpg", contentId: "<photo@x>"),
            part("5", "application/pdf", disposition: "attachment", filename: "report.pdf"),
        ]
        let markup = #"<p>Hi</p><img src="cid:logo@x">"#
        let resolved = MailEngine.userFacingAttachments(
            in: parts, bodySections: [plain.section, html.section], html: markup
        )
        XCTAssertEqual(Set(resolved.map(\.filename)), ["photo.jpg", "report.pdf"])
    }

    func testWithoutHTMLEveryPartIsAnAttachment() {
        // A plain-text-only message references nothing, so even an "inline"
        // disposition part is a real attachment.
        let plain = part("1", "text/plain")
        let parts = [
            plain,
            part("2", "image/png", disposition: "inline", filename: "logo.png", contentId: "<logo@x>"),
        ]
        let resolved = MailEngine.userFacingAttachments(
            in: parts, bodySections: [plain.section], html: nil
        )
        XCTAssertEqual(resolved.map(\.filename), ["logo.png"])
    }

    func testUnnamedAttachmentGetsTypeFallbackName() {
        let plain = part("1", "text/plain")
        let parts = [plain, part("2", "application/pdf", disposition: "attachment")]
        let resolved = MailEngine.userFacingAttachments(
            in: parts, bodySections: [plain.section], html: nil
        )
        XCTAssertEqual(resolved.map(\.filename), ["PDF"])
    }

    func testFallbackName() {
        XCTAssertEqual(MailEngine.fallbackName(for: "image/gif"), "Image")
        XCTAssertEqual(MailEngine.fallbackName(for: "application/pdf"), "PDF")
        XCTAssertEqual(MailEngine.fallbackName(for: "application/zip"), "Attachment")
    }
}
