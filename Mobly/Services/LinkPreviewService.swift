import SwiftUI

struct LinkPreviewData: Equatable {
    let url: URL
    let title: String?
    let description: String?
    let imageURL: URL?
    let domain: String
}

@MainActor
final class LinkPreviewService: ObservableObject {
    @Published var preview: LinkPreviewData?
    @Published var isLoading = false

    private var currentURL: URL?
    private static var cache: [URL: LinkPreviewData] = [:]

    func detectAndFetch(in text: String) {
        guard let url = Self.firstURL(in: text) else {
            if preview != nil { preview = nil }
            currentURL = nil
            return
        }
        guard url != currentURL else { return }
        currentURL = url

        if let cached = Self.cache[url] {
            preview = cached
            return
        }

        isLoading = true
        Task { await fetchMetadata(for: url) }
    }

    func clear() {
        preview = nil
        currentURL = nil
        isLoading = false
    }

    static func previewFor(_ text: String) -> LinkPreviewData? {
        guard let url = firstURL(in: text) else { return nil }
        return cache[url]
    }

    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let url = match.url,
              let scheme = url.scheme,
              ["http", "https"].contains(scheme.lowercased()) else { return nil }
        return url
    }

    @MainActor
    static func fetchIfNeeded(for text: String) async -> LinkPreviewData? {
        guard let url = firstURL(in: text) else { return nil }
        if let cached = cache[url] { return cached }
        return await withCheckedContinuation { cont in
            Task {
                let service = LinkPreviewService()
                await service.fetchMetadata(for: url)
                cont.resume(returning: service.preview)
            }
        }
    }

    private func fetchMetadata(for url: URL) async {
        defer { isLoading = false }
        do {
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return }
            let encoding: String.Encoding = .utf8
            guard let html = String(data: data, encoding: encoding)
                    ?? String(data: data, encoding: .ascii) else { return }

            let title = Self.extractMeta(html, property: "og:title")
                      ?? Self.extractHTMLTitle(html)
            let description = Self.extractMeta(html, property: "og:description")
            let imageStr = Self.extractMeta(html, property: "og:image")

            var imageURL: URL?
            if let img = imageStr {
                if img.hasPrefix("//") {
                    imageURL = URL(string: "https:" + img)
                } else if img.hasPrefix("/") {
                    if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                        components.path = img
                        components.query = nil
                        imageURL = components.url
                    }
                } else {
                    imageURL = URL(string: img)
                }
            }

            let domain = url.host?.replacingOccurrences(of: "www.", with: "")
                         ?? url.absoluteString

            let previewData = LinkPreviewData(
                url: url, title: title, description: description,
                imageURL: imageURL, domain: domain
            )
            Self.cache[url] = previewData
            self.preview = previewData
        } catch {
            // No preview on failure — that's fine
        }
    }

    // MARK: - HTML parsing

    private static func extractMeta(_ html: String, property: String) -> String? {
        let patterns = [
            "property=\"\(property)\"[^>]*content=\"([^\"]*)\"",
            "content=\"([^\"]*)\"[^>]*property=\"\(property)\"",
            "name=\"\(property)\"[^>]*content=\"([^\"]*)\"",
            "content=\"([^\"]*)\"[^>]*name=\"\(property)\""
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return Self.decodeHTMLEntities(value) }
        }
        return nil
    }

    private static func extractHTMLTitle(_ html: String) -> String? {
        let pattern = "<title[^>]*>([^<]+)</title>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : decodeHTMLEntities(value)
    }

    private static func decodeHTMLEntities(_ str: String) -> String {
        var result = str
        let entities = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                        ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")]
        for (entity, char) in entities { result = result.replacingOccurrences(of: entity, with: char) }
        return result
    }
}
