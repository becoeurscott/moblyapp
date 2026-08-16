import Foundation
import Combine

/// Voice-note "player" for chat bubbles.
///
/// Voice messages travel as text placeholders (`🎤 Note vocale (M:SS)`) — no
/// audio file is attached — so this simulates playback: on play the elapsed
/// counter and 0-1 progress advance every tick, driving the waveform tint and
/// timer in the bubble. When a real audio-upload pipeline lands, swap the
/// timer for `AVAudioPlayer` without changing the view surface.
@MainActor
final class AudioPlayerManager: ObservableObject {
    static let shared = AudioPlayerManager()

    /// Id of the currently active voice message, or nil when nothing is playing
    /// and no bubble is holding partial progress.
    @Published private(set) var currentId: String?
    @Published private(set) var isPlaying: Bool = false
    /// 0-1 through the note.
    @Published private(set) var progress: Double = 0
    /// Whole seconds elapsed, formatted alongside the total in the bubble.
    @Published private(set) var elapsed: Int = 0

    private var duration: Int = 0
    private var timer: Timer?

    private init() {}

    func toggle(id: String, duration: Int) {
        let d = max(duration, 1)
        if currentId == id {
            isPlaying ? pause() : resume()
        } else {
            currentId = id
            self.duration = d
            elapsed = 0
            progress = 0
            resume()
        }
    }

    private func resume() {
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard duration > 0 else { return finish() }
        progress = min(1, progress + 0.1 / Double(duration))
        elapsed = min(duration, Int(progress * Double(duration)))
        if progress >= 1 { finish() }
    }

    private func finish() {
        pause()
        progress = 0
        elapsed = 0
        currentId = nil
    }

    /// Progress to render for the given bubble — 0 unless it's the active one.
    func progress(for id: String) -> Double {
        currentId == id ? progress : 0
    }

    func isPlaying(id: String) -> Bool {
        currentId == id && isPlaying
    }

    func elapsed(for id: String, fallback: Int) -> Int {
        currentId == id ? elapsed : 0
    }
}
