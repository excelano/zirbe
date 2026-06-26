// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// Recording a voice message to attach. The recorder wraps AVAudioRecorder and the
// audio session, captures mono AAC into a temp .m4a (voice-grade, so the file
// stays small for email), and reads it back into a ZirbeCore DraftAttachment that
// joins the composer's staging tray like any other attachment. The sheet drives
// it: tap to record, stop, then re-record or attach. Everything stays on device;
// the memo only leaves when the message sends, over the same SMTP path as a photo.

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
        /// Microphone access is off, so point the user at Settings.
        case denied
    }

    private(set) var phase: Phase = .idle
    /// Seconds elapsed in the current take, polled for the live timer.
    private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var fileURL: URL?

    /// The finished take as a sendable attachment, or nil if nothing usable was
    /// captured. Named so it reads as a voice message in other mail clients too.
    func makeAttachment() -> DraftAttachment? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return DraftAttachment(filename: "Voice Message.m4a", mimeType: "audio/mp4", data: data)
    }

    /// Ask for the mic once if needed, then start, or fall to the denied state so
    /// the sheet can offer Settings. Called when record is tapped from idle.
    func start() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            beginRecording()
        case .denied:
            phase = .denied
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    granted ? self.beginRecording() : (self.phase = .denied)
                }
            }
        @unknown default:
            phase = .denied
        }
    }

    func stop() {
        guard case .recording = phase else { return }
        let duration = recorder?.currentTime ?? elapsed
        recorder?.stop()
        stopTicker()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .recorded(max(duration, 0))
    }

    /// Discard the take and return to idle so the user can record again.
    func reset() {
        recorder?.stop()
        stopTicker()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        recorder = nil
        fileURL = nil
        elapsed = 0
        if case .recording = phase {
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
            // A session or recorder failure is, for the user, the same dead end as
            // no microphone: nothing to record into.
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
}

/// The recording sheet, presented from the composer's attach menu. It walks the
/// three states (idle, recording, recorded) and hands a finished take back to the
/// composer, which stages it as a chip. A denied microphone routes to Settings.
struct VoiceRecorderSheet: View {
    /// Stage the finished recording in the composer's tray.
    let onAttach: (DraftAttachment) -> Void

    @State private var recorder = VoiceRecorder()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                content
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color.zirbeCanvas.ignoresSafeArea())
            .navigationTitle("Voice Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { recorder.reset(); dismiss() }
                }
            }
            .interactiveDismissDisabled(recorder.phase == .recording)
        }
        .presentationDetents([.height(300)])
    }

    @ViewBuilder
    private var content: some View {
        switch recorder.phase {
        case .idle:
            recordControl(label: "Tap to record") {
                Image(systemName: "mic.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
            } action: { recorder.start() }

        case .recording:
            VStack(spacing: 20) {
                Text(Self.clock(recorder.elapsed))
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                Button(action: recorder.stop) {
                    ZStack {
                        Circle().fill(.red).frame(width: 76, height: 76)
                        RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 26, height: 26)
                    }
                }
                .buttonStyle(.plain)
                Text("Recording… tap to stop")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .recorded(let duration):
            VStack(spacing: 24) {
                Label(Self.clock(duration), systemImage: "waveform")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                HStack(spacing: 14) {
                    Button { recorder.reset() } label: {
                        Label("Re-record", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 18)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button(action: attach) {
                        Label("Attach", systemImage: "arrow.up.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 22)
                            .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

        case .denied:
            VStack(spacing: 16) {
                Image(systemName: "mic.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("Microphone access is off for Zirbe. Turn it on in Settings to record a voice message.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    /// The large circular record button shared by the idle state, with a caption.
    private func recordControl<Glyph: View>(
        label: String,
        @ViewBuilder glyph: () -> Glyph,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 18) {
            Button(action: action) {
                ZStack {
                    Circle().fill(.red).frame(width: 84, height: 84)
                    glyph()
                }
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func attach() {
        if let draft = recorder.makeAttachment() { onAttach(draft) }
        dismiss()
    }

    /// Seconds as m:ss for the timer and the finished-take duration.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
