import Foundation

/// Client-side mirror of the server's password policy (`backend/src/lib/password.ts`).
///
/// This exists purely for live feedback while typing — it is **not** a control.
/// The server re-runs every rule on `/auth/signup/start` and `/verify`, because
/// anything calling the API directly skips this entirely. If the two ever
/// disagree, the server wins and the user sees a field error on submit.
enum PasswordRules {
    struct Rule {
        let label: String
        let met: Bool
    }

    static let minLength = 8

    /// - Parameter personal: name / e-mail / phone, so a password can't restate them.
    static func evaluate(_ password: String, personal: [String] = []) -> [Rule] {
        [
            Rule(label: "8 caractères minimum", met: password.count >= minLength),
            Rule(label: "Une majuscule",
                 met: password.contains(where: { $0.isUppercase })),
            Rule(label: "Une minuscule",
                 met: password.contains(where: { $0.isLowercase })),
            Rule(label: "Un chiffre",
                 met: password.contains(where: { $0.isNumber })),
            Rule(label: "Sans votre nom ni numéro",
                 met: !containsPersonal(password, personal)),
        ]
    }

    static func allMet(_ password: String, personal: [String] = []) -> Bool {
        evaluate(password, personal: personal).allSatisfy(\.met)
    }

    /// Mirrors the server's `containsPersonal`: names split on separators,
    /// e-mails reduced to their local part, phones matched on the last 6 digits
    /// (the +237 prefix is shared by everyone, so it carries no signal).
    private static func containsPersonal(_ password: String, _ personal: [String]) -> Bool {
        let lower = password.lowercased()
        guard !lower.isEmpty else { return false }

        for raw in personal {
            let value = raw.lowercased().trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }

            let digits = value.filter(\.isNumber)
            if digits.count >= 6, lower.contains(digits.suffix(6)) { return true }

            let local = value.contains("@") ? String(value.split(separator: "@")[0]) : value
            let parts = local.split(whereSeparator: { " ._-".contains($0) })
            for part in parts where part.count >= 4 && part.contains(where: \.isLetter) {
                if lower.contains(part) { return true }
            }
        }
        return false
    }
}
