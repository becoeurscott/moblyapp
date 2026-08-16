import Foundation

/// What the user appears to be typing into a combined phone/e-mail field.
enum IdentifierKind {
    case unknown   // nothing typed yet
    case email
    case phone
}

enum IdentifierDetector {
    /// Decide from the shape of the input.
    ///
    /// Any letter means e-mail — no phone number contains one, so the moment a
    /// letter appears the intent is unambiguous. `+`, digits and the usual
    /// separators mean phone. This runs on every keystroke, so it deliberately
    /// commits early rather than waiting for a complete value.
    static func detect(_ raw: String) -> IdentifierKind {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return .unknown }
        if s.contains("@") { return .email }
        if s.contains(where: { $0.isLetter }) { return .email }
        if s.contains(where: { $0.isNumber }) || s.hasPrefix("+") { return .phone }
        return .unknown
    }

    /// Group digits for readability: a leading single digit when the count is
    /// odd, then pairs — which renders a Cameroonian 677123456 as the familiar
    /// "6 77 12 34 56".
    static func formatPhone(_ digits: String) -> String {
        let d = digits.filter(\.isNumber)
        guard !d.isEmpty else { return "" }
        var chars = Array(d)
        var groups: [String] = []
        if chars.count % 2 == 1 {
            groups.append(String(chars.removeFirst()))
        }
        while !chars.isEmpty {
            groups.append(String(chars.prefix(2)))
            chars.removeFirst(min(2, chars.count))
        }
        return groups.joined(separator: " ")
    }

    static func isValidEmail(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
        let domain = t[t.index(after: at)...]
        return domain.contains(".")
            && !domain.hasPrefix(".")
            && !domain.hasSuffix(".")
            && !t.contains(" ")
    }
}
