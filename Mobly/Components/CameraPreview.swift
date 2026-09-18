import SwiftUI
import AVFoundation

/// Owns a front-camera capture session used for the local video preview.
/// Video only: no audio input is added and the session never touches the
/// app's audio session, which CallService configures for the call audio.
final class CameraPreviewController: ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var authorized = false

    private let queue = DispatchQueue(label: "mobly.camera.preview")
    private var configured = false

    init() {
        session.automaticallyConfiguresApplicationAudioSession = false
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorized = granted
                    if granted { self?.run() }
                }
            }
        default:
            authorized = false
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func run() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.configure()
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        session.commitConfiguration()
        configured = true
    }
}

/// Mirrored front-camera preview backed by AVCaptureVideoPreviewLayer.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
