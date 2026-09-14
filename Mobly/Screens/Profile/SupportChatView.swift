import SwiftUI

/// Mobly's own support conversation.
///
/// The support thread used to open in the generic `ChatThreadView`, which is
/// built for talking to an owner about a listing — listing header, visit
/// quick-replies, call buttons. None of that means anything to someone asking
/// Mobly for help. This screen is purpose-built: a support avatar, a greeting,
/// and suggested questions the user can tap instead of typing.
///
/// Answers come from the support assistant on the server (`supportAgent.ts`),
/// which writes into this same thread and can *act* — open an identity check,
/// flip an annonce's availability, cancel a visit — or hand over to a human.
/// Messages arrive over the socket through `ChatStore`, so a human taking over
/// needs no special handling here.
struct SupportChatView: View {
    let thread: ChatThread
    /// A question to send as soon as the chat opens — set when the user tapped
    /// a topic card or an FAQ's "Poser la question" in the help hub.
    var initialQuestion: String? = nil
    var onBack: () -> Void

    @ObservedObject private var chat = ChatStore.shared
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var session = Session.shared

    @State private var draft = ""
    @State private var sentInitial = false
    /// True between the user's message and the assistant's reply, so the
    /// conversation shows it is being worked on rather than looking stuck.
    @State private var awaitingReply = false
    @FocusState private var inputFocused: Bool

    private var me: String? { auth.user?.id }

    private var messages: [MessageDTO] {
        (chat.messages[thread.id] ?? []).filter { !$0.text.isEmpty }
    }

    /// Suggested questions shown above the input; tapping one sends it to the
    /// assistant as if typed.
    private let suggestions = [
        "Pourquoi mon annonce est en attente ?",
        "Comment vérifier mon identité ?",
        "Comment réserver une visite ?",
        "Je veux parler à un conseiller",
    ]

    private var greetingName: String { session.firstName }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        greeting
                        ForEach(messages) { m in
                            bubble(m).id(m.id)
                        }
                        if awaitingReply { typingBubble.id("typing") }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in
                    // A reply from anyone but me ends the wait.
                    if let last = messages.last, last.senderId != me { awaitingReply = false }
                    withAnimation(Motion.quick) { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                }
                .onChange(of: awaitingReply) { _, waiting in
                    if waiting { withAnimation(Motion.quick) { proxy.scrollTo("typing", anchor: .bottom) } }
                }
            }

            // Always reachable while the user isn't typing — someone coming
            // back to support with a new problem needs them as much as a
            // first-timer does.
            if draft.isEmpty && !awaitingReply {
                suggestionRow
            }
            composer
        }
        .background(Color.white.ignoresSafeArea())
        .task {
            await chat.loadMessages(threadId: thread.id)
            chat.markRead(threadId: thread.id)
            if let q = initialQuestion, !sentInitial {
                sentInitial = true
                send(q)
            }
        }
        .onDisappear { chat.markRead(threadId: thread.id) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(hex: 0xF1F2F5)))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text("Support Mobly")
                    .font(.moblyBody(15, weight: .semibold))
                    .foregroundStyle(Color.moblyTextPrimary)
                Text("Assistant · répond en quelques secondes")
                    .font(.moblyBody(11.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: Bubbles

    private var avatar: some View {
        ZStack {
            Circle().fill(Color(hex: 0x5AD2F4)).frame(width: 40, height: 40)
            Image(systemName: "headphones")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.moblyTextPrimary)
        }
    }

    /// Local greeting, always first. Not a server message — it would otherwise
    /// be re-posted into the thread every time someone opened support.
    private var greeting: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                Text(greetingName.isEmpty
                     ? "Bonjour. Envoyez-moi un message pour commencer."
                     : "Bonjour \(greetingName). Envoyez-moi un message pour commencer.")
                    .font(.moblyBody(14))
                    .foregroundStyle(Color.moblyTextPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(hex: 0xF1F2F5)))
            }
            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private func bubble(_ m: MessageDTO) -> some View {
        let mine = m.senderId == me
        HStack(alignment: .bottom, spacing: 10) {
            if mine { Spacer(minLength: 50) } else { avatar }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if m.kind == "IMAGE", let url = m.mediaUrl, !(m.mediaExpired ?? false) {
                    // A screenshot sent to support is usually the whole point
                    // of the message — show it, not a "📷 Photo" placeholder.
                    RemoteImage(source: url)
                        .frame(width: 200, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text(m.text)
                        .font(.moblyBody(14))
                        .foregroundStyle(mine ? .white : Color.moblyTextPrimary)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(mine ? Color.moblyPrimary : Color(hex: 0xF1F2F5)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(m.createdAt, style: .time)
                    .font(.moblyBody(10.5))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
            if !mine { Spacer(minLength: 40) }
        }
    }

    private var typingBubble: some View {
        HStack(alignment: .bottom, spacing: 10) {
            avatar
            TypingDots()
                .padding(.horizontal, 16).padding(.vertical, 15)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(hex: 0xF1F2F5)))
            Spacer()
        }
    }

    // MARK: Suggestions + composer

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { send(s) } label: {
                        Text(s)
                            .font(.moblyBody(12.5, weight: .medium))
                            .foregroundStyle(Color.moblyPrimary)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Capsule().fill(Color.moblySurfaceTint))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 10)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Votre question", text: $draft, axis: .vertical)
                .font(.moblyBody(14.5))
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send(draft) }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .background(Capsule().fill(Color(hex: 0xF1F2F5)))

            Button { send(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(canSend ? Color.moblyPrimary : Color(hex: 0xC4C7D2)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let me else { return }
        draft = ""
        awaitingReply = true
        Task {
            _ = await chat.send(threadId: thread.id, text: text, myUserId: me)
            // Don't leave the dots spinning forever if the assistant is off or
            // slow — a human reply may take far longer, and that is fine.
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            awaitingReply = false
        }
    }
}

/// Three dots that pulse in sequence.
private struct TypingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color(hex: 0x9A9DAC))
                    .frame(width: 7, height: 7)
                    .opacity(phase == i ? 1 : 0.35)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
