import Foundation
import AVFoundation
import Combine

/// Voice-note player for chat bubbles.
///
/// Supports two modes:
/// 1. **Real playback** — when a message has a registered audio file, uses
///    `AVAudioPlayer` to play the actual recording.
/// 2. **Legacy simulated playback** — for older text-only voice messages
///    (`🎤 Note vocale (M:SS)`) without an audio file. A timer advances the
///    progress bar at real-time speed.
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

    // Real audio playback
    private var audioPlayer: AVAudioPlayer?
    /// Message id -> local audio file URL
    private var audioUrls: [String: URL] = [:]
    /// Message id -> normalised samples captured during recording
    private var audioSamples: [String: [CGFloat]] = [:]
    /// Downloads in flight, so a bubble redrawing mid-fetch doesn't start a second one.
    private var remoteFetches: Set<String> = []

    private init() {}

    // MARK: - Audio registration

    /// Register a recorded voice note so it can be played back with real audio.
    func registerAudio(id: String, url: URL, samples: [CGFloat]) {
        audioUrls[id] = url
        audioSamples[id] = samples
    }

    /// Carry a registration across the optimistic → confirmed id swap, so the
    /// sender's own note keeps playing from the local file it was recorded to
    /// rather than waiting on a download of what it just uploaded.
    func rekeyAudio(from oldId: String, to newId: String) {
        guard oldId != newId else { return }
        if let url = audioUrls[oldId] { audioUrls[newId] = url }
        if let s = audioSamples[oldId] { audioSamples[newId] = s }
    }

    /// Register a note that lives on the server (i.e. one we received).
    ///
    /// `AVAudioPlayer` cannot stream: it needs bytes on disk. The file is
    /// fetched once into Caches and keyed by message id, so replaying a note —
    /// or scrolling past it again — costs nothing.
    func registerRemote(id: String, urlString: String) {
        guard audioUrls[id] == nil, remoteFetches.contains(id) == false,
              let remote = URL(string: urlString), remote.scheme?.hasPrefix("http") == true
        else { return }

        let cached = Self.cacheURL(for: id, ext: remote.pathExtension.isEmpty ? "m4a" : remote.pathExtension)
        if FileManager.default.fileExists(atPath: cached.path) {
            audioUrls[id] = cached
            return
        }

        remoteFetches.insert(id)
        Task { [weak self] in
            defer { Task { @MainActor in self?.remoteFetches.remove(id) } }
            guard let (data, resp) = try? await URLSession.shared.data(from: remote),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                  (try? data.write(to: cached)) != nil
            else { return }
            await MainActor.run { self?.audioUrls[id] = cached }
        }
    }

    private static func cacheURL(for id: String, ext: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice-notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Message ids are cuid/uuid — filesystem-safe as-is.
        return dir.appendingPathComponent("\(id).\(ext)")
    }

    /// Return the recorded waveform samples for a message, if available.
    func samples(for id: String) -> [CGFloat]? {
        audioSamples[id]
    }

    /// Whether a real audio file is registered for the given message.
    func hasRealAudio(for id: String) -> Bool {
        audioUrls[id] != nil
    }

    // MARK: - Playback

    func toggle(id: String, duration dur: Int) {
        let d = max(dur, 1)
        if currentId == id {
            // Same message — toggle pause/resume.
            if isPlaying {
                audioPlayer?.pause()
                pause()
            } else {
                if audioUrls[id] != nil {
                    audioPlayer?.play()
                }
                resume()
            }
        } else {
            // Different message — stop whatever is playing and start this one.
            stopCurrentPlayback()
            if audioUrls[id] != nil {
                playReal(id: id)
            } else {
                // Legacy fake playback
                currentId = id
                self.duration = d
                elapsed = 0
                progress = 0
                resume()
            }
        }
    }

    /// Play real audio for a message.
    private func playReal(id: String) {
        guard let url = audioUrls[id] else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            audioPlayer = player
            currentId = id
            isPlaying = true
            duration = max(1, Int(player.duration))
            elapsed = 0
            progress = 0
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tickReal() }
            }
        } catch {
            print("[AudioPlayerManager] playReal error: \(error)")
        }
    }

    private func tickReal() {
        guard let player = audioPlayer else { return }
        if !player.isPlaying {
            finish()
            return
        }
        let d = player.duration
        guard d > 0 else { return }
        progress = player.currentTime / d
        elapsed = Int(player.currentTime)
    }

    // MARK: - Legacy simulated playback

    private func resume() {
        isPlaying = true
        // Only start the simulated ticker for legacy (non-real-audio) playback.
        if audioPlayer == nil {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
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
        audioPlayer?.stop()
        audioPlayer = nil
        progress = 0
        elapsed = 0
        currentId = nil
    }

    private func stopCurrentPlayback() {
        timer?.invalidate()
        timer = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        progress = 0
        elapsed = 0
        currentId = nil
    }

    // MARK: - Query helpers

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
