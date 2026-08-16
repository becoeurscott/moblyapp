import Foundation

/// A dialling country for the phone-number field.
///
/// Only the ISO code and dial code are stored. The display name comes from
/// `Locale`, so it's automatically in the user's language (French here) and
/// stays correct as country names change — and the flag is derived from the
/// ISO code, so there are no 240 emoji literals to keep in sync.
struct Country: Identifiable, Hashable {
    /// ISO 3166-1 alpha-2, e.g. "CM".
    let iso: String
    /// E.164 country calling code without "+", e.g. "237".
    let dial: String

    var id: String { iso }

    /// Regional-indicator flag built from the ISO code.
    var flag: String {
        iso.unicodeScalars.reduce(into: "") { out, scalar in
            // 'A' (0x41) maps to REGIONAL INDICATOR SYMBOL LETTER A (0x1F1E6).
            if let indicator = UnicodeScalar(0x1F1E6 - 0x41 + scalar.value) {
                out.unicodeScalars.append(indicator)
            }
        }
    }

    /// Localised country name, falling back to the ISO code if unknown.
    var name: String {
        Locale.current.localizedString(forRegionCode: iso) ?? iso
    }

    var dialCode: String { "+\(dial)" }

    /// Matches a search across name, ISO code and dial code, accent-insensitively
    /// so "cote" finds "Côte d'Ivoire".
    func matches(_ query: String) -> Bool {
        let q = Self.fold(query)
        guard !q.isEmpty else { return true }
        return Self.fold(name).contains(q)
            || iso.lowercased().contains(q)
            || dial.contains(q.filter(\.isNumber))
            && !q.filter(\.isNumber).isEmpty
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

extension Country {
    /// Cameroon — Mobly's home market and the default selection.
    static let cameroon = Country(iso: "CM", dial: "237")

    /// Shown at the top of the picker: the home market plus the diaspora
    /// countries the backend's SMS allowlist covers by default.
    static let suggestedISO: [String] = ["CM", "FR", "BE", "CA", "US", "GB", "DE", "CH", "IT", "ES"]

    /// Default selection: **always Cameroon**.
    ///
    /// Deliberately not the device region. Mobly is Cameroon-first, and the
    /// overwhelming majority of signups are +237 — a device whose region is set
    /// elsewhere (or a simulator, which reports US) would otherwise start every
    /// new user on the wrong country code. Diaspora users pick theirs from the
    /// list, which is one tap.
    static var deviceDefault: Country { .cameroon }

    /// Look up by dial code — longest match wins, since "1" (US) would
    /// otherwise shadow "1868" (Trinidad).
    static func matching(dialCode digits: String) -> Country? {
        let d = digits.replacingOccurrences(of: "+", with: "")
        return all
            .filter { d.hasPrefix($0.dial) }
            .max { $0.dial.count < $1.dial.count }
    }

    /// Every dialling country, sorted by localised name at point of use.
    static let all: [Country] = rawTable
        .split(separator: " ")
        .compactMap { entry in
            let parts = entry.split(separator: ":")
            guard parts.count == 2 else { return nil }
            return Country(iso: String(parts[0]), dial: String(parts[1]))
        }

    /// `ISO:dial` pairs. Compact on purpose — names and flags are derived.
    private static let rawTable = """
    AF:93 AX:358 AL:355 DZ:213 AS:1684 AD:376 AO:244 AI:1264 AG:1268 AR:54 AM:374 AW:297 \
    AU:61 AT:43 AZ:994 BS:1242 BH:973 BD:880 BB:1246 BY:375 BE:32 BZ:501 BJ:229 BM:1441 \
    BT:975 BO:591 BA:387 BW:267 BR:55 IO:246 BN:673 BG:359 BF:226 BI:257 KH:855 CM:237 \
    CA:1 CV:238 KY:1345 CF:236 TD:235 CL:56 CN:86 CO:57 KM:269 CG:242 CD:243 CK:682 \
    CR:506 CI:225 HR:385 CU:53 CY:357 CZ:420 DK:45 DJ:253 DM:1767 DO:1809 EC:593 EG:20 \
    SV:503 GQ:240 ER:291 EE:372 ET:251 FK:500 FO:298 FJ:679 FI:358 FR:33 GF:594 PF:689 \
    GA:241 GM:220 GE:995 DE:49 GH:233 GI:350 GR:30 GL:299 GD:1473 GP:590 GU:1671 GT:502 \
    GG:44 GN:224 GW:245 GY:592 HT:509 HN:504 HK:852 HU:36 IS:354 IN:91 ID:62 IR:98 \
    IQ:964 IE:353 IM:44 IL:972 IT:39 JM:1876 JP:81 JE:44 JO:962 KZ:7 KE:254 KI:686 \
    KP:850 KR:82 KW:965 KG:996 LA:856 LV:371 LB:961 LS:266 LR:231 LY:218 LI:423 LT:370 \
    LU:352 MO:853 MK:389 MG:261 MW:265 MY:60 MV:960 ML:223 MT:356 MH:692 MQ:596 MR:222 \
    MU:230 YT:262 MX:52 FM:691 MD:373 MC:377 MN:976 ME:382 MS:1664 MA:212 MZ:258 MM:95 \
    NA:264 NR:674 NP:977 NL:31 NC:687 NZ:64 NI:505 NE:227 NG:234 NU:683 NF:672 MP:1670 \
    NO:47 OM:968 PK:92 PW:680 PS:970 PA:507 PG:675 PY:595 PE:51 PH:63 PL:48 PT:351 \
    PR:1787 QA:974 RE:262 RO:40 RU:7 RW:250 BL:590 SH:290 KN:1869 LC:1758 MF:590 PM:508 \
    VC:1784 WS:685 SM:378 ST:239 SA:966 SN:221 RS:381 SC:248 SL:232 SG:65 SK:421 SI:386 \
    SB:677 SO:252 ZA:27 SS:211 ES:34 LK:94 SD:249 SR:597 SZ:268 SE:46 CH:41 SY:963 \
    TW:886 TJ:992 TZ:255 TH:66 TL:670 TG:228 TK:690 TO:676 TT:1868 TN:216 TR:90 TM:993 \
    TC:1649 TV:688 UG:256 UA:380 AE:971 GB:44 US:1 UY:598 UZ:998 VU:678 VA:39 VE:58 \
    VN:84 WF:681 EH:212 YE:967 ZM:260 ZW:263
    """
}
