import AVFoundation
import Combine

/// Records voice notes using `AVAudioRecorder`, exposing live metering data
/// for a real-time waveform in the chat composer. The output is an `.m4a` file
/// written to the app's caches directory.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    /// Normalised 0-1 audio levels sampled every ~50 ms, used to drive the
    /// live recording waveform.
    @Published private(set) var samples: [CGFloat] = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startTime: Date?
    /// Resolved from `audioRecorderDidFinishRecording`, so a caller only reads
    /// the `.m4a` once AVAudioRecorder has actually flushed and closed it.
    private var finishContinuation: CheckedContinuation<Void, Never>?

    /// Call once when the chat view appears so the permission dialog shows
    /// early rather than blocking the first recording attempt.
    func requestPermissionIfNeeded() {
        guard AVAudioSession.sharedInstance().recordPermission == .undetermined else { return }
        if #available(iOS 17, *) {
            AVAudioApplication.requestRecordPermission { _ in }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        }
    }

    /// Begin recording from the microphone.
    func startRecording() {
        let permission = AVAudioSession.sharedInstance().recordPermission
        guard permission == .granted else {
            if permission == .undetermined {
                requestPermissionIfNeeded()
            }
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return
        }

        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("voice_\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            rec.isMeteringEnabled = true
            rec.record()
            recorder = rec
            isRecording = true
            startTime = Date()
            samples = []
            duration = 0

            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMeters() }
            }
        } catch {
            return
        }
    }

    /// Called ~20 times/sec to sample microphone power and update the elapsed
    /// timer.
    private func updateMeters() {
        guard let rec = recorder, rec.isRecording else { return }
        rec.updateMeters()
        // averagePower returns dB in –160…0. Map the useful range –50…0 to
        // 0…1 so moderate speech centres around 0.4-0.7 and silence is flat.
        let power = rec.averagePower(forChannel: 0)
        let level = max(0, min(1, CGFloat((power + 50) / 50)))
        samples.append(level)
        duration = Date().timeIntervalSince(startTime ?? Date())
    }

    /// Stop recording and return the audio file URL, the real duration, and
    /// the sampled levels. Returns `nil` if nothing was recording.
    ///
    /// `AVAudioRecorder.stop()` finalises the MPEG-4 container (the `moov`
    /// atom) asynchronously, so reading the file the instant `stop()` returns
    /// could ship a truncated or empty note. This awaits the delegate callback
    /// before handing the URL back, guaranteeing a complete, playable file.
    func stopRecording() async -> (url: URL, duration: TimeInterval, samples: [CGFloat])? {
        timer?.invalidate()
        timer = nil
        guard let rec = recorder, isRecording else {
            isRecording = false
            return nil
        }
        let d = rec.currentTime
        let url = rec.url
        let capturedSamples = samples
        isRecording = false

        // Wait for the delegate to confirm the file is flushed, BUT never hang
        // on it: `audioRecorderDidFinishRecording` is not guaranteed to fire
        // (an interrupted session, or some devices/simulator, simply never call
        // it). Without a fallback the continuation would never resume and the
        // whole voice note would silently never send — the "voice ne s'envoie
        // pas" bug. So we also arm a short timeout; whichever fires first wins,
        // and `resumeFinish()` guarantees the continuation resumes exactly once.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            finishContinuation = cont
            rec.stop() // delegate resolves the continuation (fast path)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.resumeFinish() // safety net if the delegate never fires
            }
        }

        recorder = nil
        duration = 0
        samples = []
        return (url: url, duration: d, samples: capturedSamples)
    }

    /// Resume the stop() continuation exactly once, whether woken by the
    /// delegate or the timeout.
    private func resumeFinish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    // MARK: - AVAudioRecorderDelegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder,
                                                     successfully _: Bool) {
        Task { @MainActor in
            self.resumeFinish()
        }
    }

    /// Cancel a recording in progress, deleting the temporary file.
    func cancelRecording() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        if let url = recorder?.url {
            try? FileManager.default.removeItem(at: url)
        }
        recorder = nil
        isRecording = false
        duration = 0
        samples = []
    }
}
