// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)

import SwiftUI
import AVFoundation
import ZirbeCore

@MainActor
@Observable
final class VoiceRecorder {
    enum Phase: Equatable {
        case idle
        case recording
        case recorded(TimeInterval)
        case denied
    }

    enum Transcript: Equatable {
        case pending
        case done(String)
        case unavailable
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var transcript: Transcript = .pending
    private(set) var playback = AudioPlayback()

    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var transcribing: Task<Void, Never>?
    private var fileURL: URL?

    func makeAttachment() -> DraftAttachment? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return DraftAttachment(filename: "Voice Message.m4a", mimeType: "audio/mp4", data: data)
    }

    var finishedTranscript: String? {
        guard case .done(let words) = transcript, !words.isEmpty else { return nil }
        return words
    }

    func start() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            phase = .denied
        case .undetermined:
            Task {
                let granted = await AVAudioApplication.requestRecordPermission()
                granted ? beginRecording() : (phase = .denied)
            }
        @unknown default:
            phase = .denied
        }
    }

    func stop() {
        guard case .recording = phase, let fileURL else { return }
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        stopTicker()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .recorded(max(duration, 0))
        if let data = try? Data(contentsOf: fileURL) { _ = playback.load(data) }
        transcribing = Task { [weak self] in
            let words = try? await Transcriber.transcribe(fileURL)
            guard !Task.isCancelled, let self else { return }
            self.transcript = words.map(Transcript.done) ?? .unavailable
        }
    }

    func reset() {
        let wasRecording = phase == .recording
        recorder?.stop()
        stopTicker()
        transcribing?.cancel()
        transcribing = nil
        playback.stop()
        playback = AudioPlayback()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        recorder = nil
        fileURL = nil
        elapsed = 0
        transcript = .pending
        if wasRecording {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        phase = .idle
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString.prefix(8)).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            self.recorder = recorder
            self.fileURL = url
            self.elapsed = 0
            self.phase = .recording
            startTicker()
        } catch {
            phase = .denied
        }
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let recorder = self.recorder, recorder.isRecording else { break }
                self.elapsed = recorder.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct VoiceStrip: View {
    let recorder: VoiceRecorder
    let canSend: Bool
    let onSend: () -> Void

    var body: some View {
        Group {
            switch recorder.phase {
            case .idle:
                EmptyView()
            case .recording:
                recording
            case .recorded:
                review
            case .denied:
                denied
            }
        }
        .sensoryFeedback(trigger: recorder.phase) { old, new in
            if new == .recording { return .start }
            if old == .recording { return .stop }
            return nil
        }
    }

    private var recording: some View {
        HStack(spacing: 12) {
            discardButton
            Circle().fill(.red).frame(width: 10, height: 10)
            Text(VoiceRecorder.clock(recorder.elapsed))
                .font(.body.monospacedDigit())
            Spacer()
            Button(action: recorder.stop) {
                ZStack {
                    Circle().fill(.red).frame(width: 30, height: 30)
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 11, height: 11)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 36)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 6) {
            transcriptLine
            HStack(spacing: 12) {
                discardButton
                Button(action: recorder.playback.toggle) {
                    Image(systemName: recorder.playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(recorder.playback.isPlaying ? "Pause" : "Play")
                AudioProgressTrack(progress: recorder.playback.progress, tint: .accentColor)
                Text(VoiceRecorder.clock(shownTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(!canSend)
                .accessibilityLabel("Send voice message")
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var transcriptLine: some View {
        switch recorder.transcript {
        case .pending:
            Text("Transcribing…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .done(let words) where !words.isEmpty:
            Text(words)
                .font(.footnote)
                .lineLimit(4)
        case .done, .unavailable:
            EmptyView()
        }
    }

    private var denied: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.slash")
                .foregroundStyle(.secondary)
            Text("Microphone access is off for Zirbe.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote)
            discardButton
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 36)
    }

    private var discardButton: some View {
        Button(action: recorder.reset) {
            Image(systemName: "trash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color(.secondarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Discard voice message")
    }

    private var shownTime: TimeInterval {
        let playback = recorder.playback
        if playback.isPlaying || playback.currentTime > 0 { return playback.currentTime }
        if case .recorded(let duration) = recorder.phase { return duration }
        return 0
    }
}
