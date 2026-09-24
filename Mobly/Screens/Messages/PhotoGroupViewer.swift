import SwiftUI

/// Opens a group of photos from the chat, WhatsApp-style.
///
/// 1. First, every photo in the group is shown in a vertical list you can
///    scroll through.
/// 2. Tapping a photo opens it full screen. From there you swipe left and
///    right between the photos of the group.
/// 3. Swiping down (or tapping ✕) closes the full view and brings you back to
///    the vertical list; the list's own ✕ closes everything.
struct PhotoGroupViewer: View {
    let urls: [URL]
    var startIndex: Int = 0
    var onClose: () -> Void
    var onReply: ((Int) -> Void)?

    @State private var fullScreenIndex: Int?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                            ReplyablePhoto(url: url, index: i, onTap: {
                                withAnimation(Motion.standard) { fullScreenIndex = i }
                            }, onReply: onReply != nil ? {
                                onReply?(i)
                            } : nil)
                            .id(i)
                        }
                    }
                    .padding(.top, 64)
                    .padding(.bottom, 30)
                }
                .onAppear {
                    if startIndex > 0 { proxy.scrollTo(startIndex, anchor: .top) }
                }
            }

            header
        }
        .statusBarHidden()
        .overlay {
            if let i = fullScreenIndex {
                PagedPhotoViewer(urls: urls, startIndex: i,
                                 onClose: { withAnimation(Motion.standard) { fullScreenIndex = nil } },
                                 onReply: onReply != nil ? { idx in onReply?(idx) } : nil)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        VStack {
            HStack {
                Text("\(urls.count) photos")
                    .font(.moblyBody(14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.white.opacity(0.18)))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 54)
            .padding(.bottom, 10)
            .background(LinearGradient(colors: [.black.opacity(0.75), .clear],
                                       startPoint: .top, endPoint: .bottom))
            Spacer()
        }
    }
}

private struct ReplyablePhoto: View {
    let url: URL
    let index: Int
    let onTap: () -> Void
    let onReply: (() -> Void)?

    @State private var dragX: CGFloat = 0
    @State private var showHint = false

    var body: some View {
        ZStack(alignment: .leading) {
            if dragX > 20 {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Répondre")
                        .font(.moblyBody(13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.leading, 16)
                .opacity(min(dragX / 60, 1))
                .scaleEffect(min(dragX / 60, 1), anchor: .leading)
            }

            RemoteImage(source: url.absoluteString, width: 900, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .offset(x: dragX)
                .gesture(replyGesture)
                .onTapGesture(perform: onTap)
        }
    }

    private var replyGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { v in
                guard onReply != nil else { return }
                guard abs(v.translation.width) > abs(v.translation.height) else { return }
                if v.translation.width > 0 {
                    dragX = min(v.translation.width, 100)
                    if dragX > 55 && !showHint {
                        showHint = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
            .onEnded { v in
                guard onReply != nil else { return }
                if v.translation.width > 55 {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(Motion.quick) { dragX = 0 }
                    onReply?()
                } else {
                    withAnimation(Motion.panel) { dragX = 0 }
                }
                showHint = false
            }
    }
}

/// Full-screen photos you swipe through left and right. Swipe down to close.
struct PagedPhotoViewer: View {
    let urls: [URL]
    var startIndex: Int = 0
    var onClose: () -> Void
    var onReply: ((Int) -> Void)?

    @State private var index: Int?
    @State private var dragY: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(abs(dragY) / 400, 0.6))
                .ignoresSafeArea()

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { i, url in
                        ZoomablePage(url: url)
                            .containerRelativeFrame(.horizontal)
                            .id(i)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $index)
            .offset(y: dragY)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { v in
                        guard abs(v.translation.height) > abs(v.translation.width) else { return }
                        dragY = v.translation.height
                    }
                    .onEnded { v in
                        if abs(v.translation.height) > abs(v.translation.width),
                           abs(v.translation.height) > 110 {
                            onClose()
                        } else {
                            withAnimation(Motion.panel) { dragY = 0 }
                        }
                    }
            )

            VStack {
                HStack {
                    Text("\((index ?? startIndex) + 1) / \(urls.count)")
                        .font(.moblyBody(13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.18)))
                    Spacer()
                    if onReply != nil {
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onReply?(index ?? startIndex)
                        } label: {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(Circle().fill(.white.opacity(0.18)))
                        }
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(.white.opacity(0.18)))
                    }
                }
                .padding(.horizontal, 18).padding(.top, 54)
                Spacer()
            }
            .opacity(dragY == 0 ? 1 : 0)
        }
        .onAppear { index = startIndex }
    }

    /// One photo. Pinch to zoom; it springs back to fit when released, so the
    /// paging and swipe-down gestures are never fighting a zoomed image.
    private struct ZoomablePage: View {
        let url: URL
        @State private var scale: CGFloat = 1

        var body: some View {
            RemoteImage(source: url.absoluteString, width: 1400, contentMode: .fit)
                .scaleEffect(scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(
                    MagnifyGesture()
                        .onChanged { scale = max(1, $0.magnification) }
                        .onEnded { _ in withAnimation(Motion.panel) { scale = 1 } }
                )
        }
    }
}
