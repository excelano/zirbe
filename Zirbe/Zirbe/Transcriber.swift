// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import AVFoundation
import Speech
import ZirbeCore

enum Transcriber {
    static func transcribe(_ file: URL) async throws -> String {
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            return try await analyze(file, with: transcriber) {
                try await transcriber.results.reduce(into: []) { $0.append(String($1.text.characters)) }
            }
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else {
            throw CocoaError(.featureUnsupported)
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        return try await analyze(file, with: transcriber) {
            try await transcriber.results.reduce(into: []) { $0.append(String($1.text.characters)) }
        }
    }

    static func transcribeVideo(_ file: URL) async throws -> String {
        guard let audio = try await VideoExport.audioTrack(of: file) else { return "" }
        defer { try? FileManager.default.removeItem(at: audio) }
        return try await transcribe(audio)
    }

    private static func analyze(_ file: URL, with module: any SpeechModule,
                                results: @escaping @Sendable () async throws -> [String]) async throws -> String {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let collected = Task { try await results() }
        let audio = try AVAudioFile(forReading: file)
        if let end = try await analyzer.analyzeSequence(from: audio) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected.value
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

@MainActor
enum TranscriptionQueue {
    private static var tail: Task<Void, Never>?
    private static var tasks: [String: Task<String?, Never>] = [:]

    static func transcribe(_ attachment: MessageAttachment, of messageID: String, in model: InboxModel) async -> String? {
        if let task = tasks[messageID] { return await task.value }
        let previous = tail
        let work = Task { () -> String? in
            await previous?.value
            guard let data = await model.cachedAttachmentData(messageID: messageID, attachment: attachment) else { return nil }
            let isVideo = attachment.mimeType.lowercased().hasPrefix("video/")
            let named = (attachment.filename as NSString).pathExtension
            let ext = named.isEmpty ? (isVideo ? "mp4" : "m4a") : named
            let file = FileManager.default.temporaryDirectory
                .appending(path: "transcribe-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: file) }
            guard (try? data.write(to: file)) != nil else { return nil }
            let transcription: String?
            if isVideo {
                transcription = try? await Transcriber.transcribeVideo(file)
            } else {
                transcription = try? await Transcriber.transcribe(file)
            }
            guard let words = transcription else { return nil }
            await model.storeTranscript(words, messageID: messageID)
            return words
        }
        tasks[messageID] = work
        tail = Task { _ = await work.value }
        return await work.value
    }
}
