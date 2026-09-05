import SwiftUI

struct LinkPreviewCard: View {
    let preview: LinkPreviewData
    var fromMe: Bool = false
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let imageURL = preview.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 140)
                            .clipped()
                    case .failure:
                        EmptyView()
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 140)
                    }
                }
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if let title = preview.title, !title.isEmpty {
                        Text(title)
                            .font(.moblyBody(13, weight: .semibold))
                            .foregroundStyle(fromMe ? .white : Color.moblyTextPrimary)
                            .lineLimit(2)
                    }
                    Text(preview.domain)
                        .font(.moblyBody(11))
                        .foregroundStyle(fromMe ? .white.opacity(0.7) : .secondary)
                }
                Spacer(minLength: 0)
                if let dismiss = onDismiss {
                    Button(action: dismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(fromMe ? .white.opacity(0.6) : Color(hex: 0x9A9DAC))
                    }
                }
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(fromMe ? Color.white.opacity(0.15) : Color(hex: 0xF4F5F8))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ComposerLinkPreview: View {
    let preview: LinkPreviewData
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let imageURL = preview.imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        Color(hex: 0xE2E4EC)
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 3) {
                if let title = preview.title, !title.isEmpty {
                    Text(title)
                        .font(.moblyBody(12.5, weight: .semibold))
                        .foregroundStyle(Color.moblyTextPrimary)
                        .lineLimit(2)
                }
                Text(preview.domain)
                    .font(.moblyBody(11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color(hex: 0x9A9DAC))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0xF4F5F8))
        )
    }
}

struct MessageLinkPreview: View {
    let text: String
    let fromMe: Bool
    @State private var preview: LinkPreviewData?

    var body: some View {
        if let preview {
            LinkPreviewCard(preview: preview, fromMe: fromMe)
                .padding(.top, 6)
        } else {
            Color.clear.frame(height: 0)
                .task { await fetchPreview() }
        }
    }

    private func fetchPreview() async {
        if let cached = LinkPreviewService.previewFor(text) {
            self.preview = cached
            return
        }
        self.preview = await LinkPreviewService.fetchIfNeeded(for: text)
    }
}
