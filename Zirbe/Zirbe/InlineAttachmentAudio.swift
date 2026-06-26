// Author: David M. Anderson
// Built with AI assistance (Claude, Anthropic)
//
// An audio attachment shown inline in its bubble as a small player, the way a
// voice message reads in a chat rather than as a filename to tap. It loads the
// bytes through the model on first play (the cache, instant for a memo you just
// sent or one played before, then a fetch by part section), plays them with
// AVAudioPlayer, and shows a progress track and a running time. Any audio file
// gets this, not just Zirbe recordings. If the bytes can't be had it falls back
// to the plain chip so the file is still named and reachable in QuickLook.

import SwiftUI
import AVFoundation
import ZirbeCore

/// Owns the AVAudioPlayer for one bubble and publishes play state and progress.
/// Time is polled off the player rather than driven by its delegate, so playback
/// reset falls out of the same loop that updates the clock.
@MainActor
@Observable
final class AudioPlayback {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLoaded = false

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    /// Decode the bytes into a ready player; false if they aren't playable audio.
    func load(_ data: Data) -> Bool {
        do {
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            isLoaded = true
            return true
        } catch {
            return false
        }
    }

    func toggle() {
        guard let player else { return }
        player.isPlaying ? pause() : play()
    }

    private func play() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        startTicker()
    }

    private func pause() {
        player?.pause()
        currentTime = player?.currentTime ?? currentTime
        isPlaying = false
        stopTicker()
    }

    /// Playback ran to the end: rewind to the start and release the session so
    /// other audio (and the silent switch) goes back to normal.
    private func finish() {
        isPlaying = false
        stopTicker()
        player?.currentTime = 0
        currentTime = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let player = self.player else { break }
                if player.isPlaying {
                    self.currentTime = player.currentTime
                } else {
                    self.finish()
                    break
                }
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}

struct InlineAttachmentAudio: View {
    let model: InboxModel
    let messageID: String
    let attachment: MessageAttachment
    let isOwn: Bool

    @State private var playback = AudioPlayback()
    @State private var isLoading = false
    /// Set once the bytes can't be loaded, switching to the chip fallback.
    @State private var failed = false

    /// White on an own (accent) bubble, accent on an incoming one, matching the
    /// chip's tinting so a voice message reads as part of its bubble either way.
    private var tint: Color { isOwn ? .white : .accentColor }

    var body: some View {
        if failed {
            AttachmentChip(model: model, messageID: messageID, attachment: attachment, isOwn: isOwn)
        } else {
            HStack(spacing: 10) {
                playButton
                VStack(alignment: .leading, spacing: 5) {
                    progressTrack
                    Text(timeLabel)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(tint.opacity(0.85))
                }
            }
            .frame(width: 210)
            .padding(.vertical, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Voice message")
            .accessibilityValue(playback.isLoaded ? VoiceRecorderSheet.clock(playback.duration) : "")
            .accessibilityAddTraits(.isButton)
        }
    }

    private var playButton: some View {
        Button(action: tap) {
            ZStack {
                Circle().fill(tint.opacity(isOwn ? 0.22 : 0.15)).frame(width: 34, height: 34)
                if isLoading {
                    ProgressView().controlSize(.mini).tint(tint)
                } else {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                        // Nudge the play triangle to its optical center.
                        .offset(x: playback.isPlaying ? 0 : 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var progressTrack: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.25))
                Capsule().fill(tint).frame(width: geo.size.width * playback.progress)
            }
        }
        .frame(height: 3)
    }

    /// The total duration before it has played, the running time once it has: the
    /// label a chat audio player shows. Before the bytes load there's no duration
    /// yet, so it names itself instead.
    private var timeLabel: String {
        guard playback.isLoaded else { return "Voice Message" }
        let shown = (playback.isPlaying || playback.currentTime > 0) ? playback.currentTime : playback.duration
        return VoiceRecorderSheet.clock(shown)
    }

    /// First tap loads the bytes and starts playing; later taps just toggle. A
    /// load failure drops to the chip rather than leaving a dead control.
    private func tap() {
        if playback.isLoaded { playback.toggle(); return }
        guard !isLoading else { return }
        isLoading = true
        Task {
            let data = await model.cachedAttachmentData(messageID: messageID, attachment: attachment)
            isLoading = false
            guard let data, playback.load(data) else { failed = true; return }
            playback.toggle()
        }
    }
}
