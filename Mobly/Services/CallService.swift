import AVFoundation
import AudioToolbox
import UIKit

@MainActor
final class CallService: ObservableObject {
    static let shared = CallService()

    enum State: Equatable {
        case idle
        case outgoing
        case incoming
        case connected
        case ended
    }

    @Published var state: State = .idle
    @Published private(set) var callId: String?
    @Published private(set) var threadId: String?
    @Published private(set) var peerName: String = ""
    @Published private(set) var peerId: String = ""
    @Published var isVideo: Bool = false
    @Published private(set) var seconds: Int = 0
    @Published var muted: Bool = false
    @Published var speaker: Bool = false

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var timer: Timer?
    private var ringPlayer: AVAudioPlayer?

    private let commonFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    // MARK: - Outgoing

    func startCall(thread: ChatThread, isVideo: Bool) {
        guard state == .idle else { return }
        let id = UUID().uuidString
        callId = id
        threadId = thread.id
        peerId = thread.peerId ?? ""
        peerName = thread.name
        self.isVideo = isVideo
        state = .outgoing
        seconds = 0

        ChatStore.shared.socket.sendCallStart(callId: id, threadId: thread.id, isVideo: isVideo)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        startRingBackTone()
    }

    // MARK: - Incoming

    func handleIncoming(callId: String, threadId: String, fromId: String, fromName: String, isVideo: Bool) {
        guard state == .idle else {
            ChatStore.shared.socket.sendCallReject(callId: callId)
            return
        }
        self.callId = callId
        self.threadId = threadId
        peerId = fromId
        peerName = fromName
        self.isVideo = isVideo
        state = .incoming

        startIncomingRing()
    }

    func acceptCall() {
        guard state == .incoming, let callId else { return }
        stopRinging()
        state = .connected
        ChatStore.shared.socket.sendCallAccept(callId: callId)
        startAudio()
        startTimer()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func rejectCall() {
        guard let callId else { return }
        stopRinging()
        ChatStore.shared.socket.sendCallReject(callId: callId)
        cleanup()
    }

    func endCall() {
        guard let callId else { return }
        stopRinging()
        ChatStore.shared.socket.sendCallEnd(callId: callId)
        cleanup()
    }

    // MARK: - Events from socket

    func handleAccepted() {
        guard state == .outgoing else { return }
        stopRinging()
        state = .connected
        startAudio()
        startTimer()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func handleRejected() {
        guard state == .outgoing else { return }
        stopRinging()
        state = .ended
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.cleanup()
        }
    }

    func handleEnded() {
        guard state != .idle else { return }
        state = .ended
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.cleanup()
        }
    }

    nonisolated func handleAudioData(_ data: Data) {
        Task { @MainActor in
            playAudioData(data)
        }
    }

    // MARK: - Audio engine

    private func startAudio() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
        } catch {
            print("[CallService] Audio session error: \(error)")
            return
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: commonFormat)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: inputFormat, to: commonFormat) else {
            print("[CallService] Cannot create audio converter")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let isMuted = Task { @MainActor in self.muted }
            Task {
                let muted = await isMuted.value
                if muted { return }

                let ratio = self.commonFormat.sampleRate / inputFormat.sampleRate
                let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
                guard frameCount > 0,
                      let out = AVAudioPCMBuffer(pcmFormat: self.commonFormat, frameCapacity: frameCount)
                else { return }

                var error: NSError?
                converter.convert(to: out, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard error == nil, out.frameLength > 0 else { return }

                let data = self.bufferToData(out)
                await MainActor.run {
                    ChatStore.shared.socket.sendCallAudio(data)
                }
            }
        }

        do {
            try engine.start()
            player.play()
        } catch {
            print("[CallService] Engine start error: \(error)")
        }

        audioEngine = engine
        playerNode = player
    }

    private func stopAudio() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func playAudioData(_ data: Data) {
        guard state == .connected, let player = playerNode,
              let buffer = dataToBuffer(data) else { return }
        player.scheduleBuffer(buffer)
    }

    // MARK: - Conversion helpers

    private nonisolated func bufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        let ab = buffer.audioBufferList.pointee.mBuffers
        return Data(bytes: ab.mData!, count: Int(ab.mDataByteSize))
    }

    private nonisolated func dataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: commonFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        _ = data.withUnsafeBytes { raw in
            memcpy(buffer.audioBufferList.pointee.mBuffers.mData, raw.baseAddress, data.count)
        }
        return buffer
    }

    // MARK: - Controls

    func toggleMute() { muted.toggle() }

    func toggleSpeaker() {
        speaker.toggle()
        try? AVAudioSession.sharedInstance()
            .overrideOutputAudioPort(speaker ? .speaker : .none)
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.seconds += 1 }
        }
    }

    func cleanup() {
        stopRinging()
        stopAudio()
        timer?.invalidate()
        timer = nil
        state = .idle
        callId = nil
        threadId = nil
        peerName = ""
        peerId = ""
        isVideo = false
        seconds = 0
        muted = false
        speaker = false
    }

    var timeString: String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Ring tones

    private func startRingBackTone() {
        let data = Self.generateTone(
            frequency: 440, secondaryFrequency: 480,
            ringSeconds: 1.0, pauseSeconds: 3.0
        )
        playRingData(data)
    }

    private func startIncomingRing() {
        let data = Self.generateTone(
            frequency: 440, secondaryFrequency: 500,
            ringSeconds: 0.8, pauseSeconds: 1.6
        )
        playRingData(data)
        AudioServicesPlayAlertSound(SystemSoundID(kSystemSoundID_Vibrate))
    }

    private func playRingData(_ data: Data) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1
            player.volume = 0.6
            player.play()
            ringPlayer = player
        } catch {
            print("[CallService] Ring playback error: \(error)")
        }
    }

    private func stopRinging() {
        ringPlayer?.stop()
        ringPlayer = nil
    }

    private nonisolated static func generateTone(
        frequency: Double, secondaryFrequency: Double,
        ringSeconds: Double, pauseSeconds: Double
    ) -> Data {
        let sampleRate: Double = 44100
        let totalDuration = ringSeconds + pauseSeconds
        let totalSamples = Int(sampleRate * totalDuration)
        let ringSamples = Int(sampleRate * ringSeconds)
        let fadeLen = Int(sampleRate * 0.02)

        var pcm = Data(capacity: totalSamples * 2)
        for i in 0..<totalSamples {
            let sample: Int16
            if i < ringSamples {
                let t = Double(i) / sampleRate
                let wave = sin(2 * .pi * frequency * t) + sin(2 * .pi * secondaryFrequency * t)
                var amp = wave * 0.15 * 32767
                if i < fadeLen { amp *= Double(i) / Double(fadeLen) }
                if i > ringSamples - fadeLen { amp *= Double(ringSamples - i) / Double(fadeLen) }
                sample = Int16(clamping: Int(amp))
            } else {
                sample = 0
            }
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }

        var wav = Data(capacity: 44 + pcm.count)
        func appendU32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: [0x52,0x49,0x46,0x46]) // RIFF
        appendU32(UInt32(36 + pcm.count))
        wav.append(contentsOf: [0x57,0x41,0x56,0x45]) // WAVE
        wav.append(contentsOf: [0x66,0x6D,0x74,0x20]) // fmt
        appendU32(16); appendU16(1); appendU16(1)
        appendU32(44100); appendU32(88200)
        appendU16(2); appendU16(16)
        wav.append(contentsOf: [0x64,0x61,0x74,0x61]) // data
        appendU32(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
