import AVFoundation
import Combine

/// Records voice notes using `AVAudioRecorder`, exposing live metering data
/// for a real-time waveform in the chat composer. The output is an `.m4a` file
/// written to the app's caches directory.
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    /// Normalised 0-1 audio levels sampled every ~50 ms, used to drive the
    /// live recording waveform.
    @Published private(set) var samples: [CGFloat] = []

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startTime: Date?

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
    func stopRecording() -> (url: URL, duration: TimeInterval, samples: [CGFloat])? {
        timer?.invalidate()
        timer = nil
        guard let rec = recorder, isRecording else {
            isRecording = false
            return nil
        }
        let d = rec.currentTime
        rec.stop()
        isRecording = false
        let result = (url: rec.url, duration: d, samples: samples)
        recorder = nil
        duration = 0
        samples = []
        return result
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
