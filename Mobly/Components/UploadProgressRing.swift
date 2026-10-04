import SwiftUI

/// Upload progress over a chat photo: a grey track that fills blue as the
/// bytes actually leave the device, then disappears so the photo is clean.
///
/// Driven by real `URLSession` bytes-sent rather than an animation on a timer.
/// A spinner that moves regardless of the network tells the user nothing —
/// worse, it looks identical whether the upload is flying or stalled. This can
/// sit still, and that stillness is information.
struct UploadProgressRing: View {
    /// 0…1. Values below `visibleFloor` still show a sliver so the ring never
    /// looks empty-and-broken at the instant a send begins.
    var progress: Double
    var size: CGFloat = 46
    var lineWidth: CGFloat = 4

    private var shown: CGFloat { max(0.04, min(1, CGFloat(progress))) }

    var body: some View {
        ZStack {
            // Scrim so the ring reads against any photo underneath.
            Circle()
                .fill(Color.black.opacity(0.28))
                .frame(width: size + lineWidth * 3, height: size + lineWidth * 3)

            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: lineWidth)
                .frame(width: size, height: size)

            Circle()
                .trim(from: 0, to: shown)
                .stroke(Color.moblyPrimary,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))   // start at 12 o'clock
                .animation(Motion.quick, value: shown)
        }
        .allowsHitTesting(false)
    }
}

/// The same progress, sized and shaped for a voice bubble: it replaces the
/// duration at the end of the waveform rather than covering the bubble, so the
/// note still reads as a note while it sends.
struct VoiceUploadIndicator: View {
    var progress: Double
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.08, min(1, CGFloat(progress))))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Motion.quick, value: progress)
        }
        .frame(width: 14, height: 14)
    }
}
