import Foundation

/// The Telegram *application* pair (`api_id` / `api_hash`).
///
/// Telegram issues these per application, not per person — every Telegram
/// client ships its own — so the product is supposed to carry one and a user
/// connecting their chats should never meet my.telegram.org. That was written
/// into `scripts/connect-telegram.sh` ("the app ships them as
/// MOE_TELEGRAM_API_ID/HASH") and never implemented on this side, so the row
/// asked for a phone number and then failed, every time, for everyone.
///
/// Three places to find a pair, in order:
///
/// 1. The one built into this copy of Memoe (`build.sh` writes it into
///    Info.plist from the release environment). Nothing to type.
/// 2. One the user has already given, which `connect-telegram.sh` stored in
///    `~/.moe/connectors/telegram.json`. Also nothing to type.
/// 3. Neither — so the sheet asks for one, with the steps and the link, and
///    the script stores it. Still no Terminal.
enum TelegramAppKeys {
    struct Pair: Equatable {
        var id: String
        var hash: String
        var isUsable: Bool { !id.isEmpty && !hash.isEmpty }
    }

    /// The pair this build ships, if it was built with one.
    static var shipped: Pair? {
        let info = Bundle.main.infoDictionary ?? [:]
        let pair = Pair(id: string(info["MoeTelegramAPIID"]), hash: string(info["MoeTelegramAPIHash"]))
        return pair.isUsable ? pair : nil
    }

    /// The pair already saved on this Mac, written by connect-telegram.sh
    /// after a successful sign-in (or an earlier attempt at one).
    static var stored: Pair? { stored(in: Paths.home) }

    /// `home` is an argument so this can be tested without a real ~/.moe.
    static func stored(in home: URL) -> Pair? {
        let url = home.appendingPathComponent("connectors/telegram.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let pair = Pair(id: string(obj["api_id"]), hash: string(obj["api_hash"]))
        return pair.isUsable ? pair : nil
    }

    /// What the flow should use, or nil when the user has to be asked.
    static var resolved: Pair? { shipped ?? stored }

    /// `api_id` is a number on Telegram's side and the script rejects
    /// anything else before it gets as far as the network — so say it here,
    /// where the cursor still is.
    /// The first line with anything on it.
    ///
    /// my.telegram.org shows the api_id and the api_hash stacked, and
    /// selecting them gives you both with a newline between. Trimming the
    /// ends does nothing for a newline in the middle, so a perfectly ordinary
    /// copy came out as "not just digits" over a box that plainly showed
    /// digits — the second line was below the fold.
    static func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    /// The api_id as the script wants it: digits, nothing else.
    static func normalisedID(_ s: String) -> String {
        String(firstLine(s).filter { $0.isASCII && $0.isNumber })
    }

    /// The api_hash as the script wants it: lowercase hex, nothing else.
    static func normalisedHash(_ s: String) -> String {
        String(firstLine(s).filter { $0.isASCII && $0.isHexDigit }).lowercased()
    }

    static func isValidID(_ s: String) -> Bool {
        !normalisedID(s).isEmpty
    }

    /// Telegram's api_hash is exactly 32 hexadecimal characters. Checking
    /// the shape here catches the thing that actually happens: the value is
    /// pasted twice, the field shows the first 32 and scrolls the rest out
    /// of sight, and Telegram answers ApiIdInvalidError — which reads as a
    /// problem with the phone number unless someone tells you otherwise.
    static func isValidHash(_ s: String) -> Bool {
        normalisedHash(s).count == 32
    }

    /// The phone number as the script wants it: `+` and digits, nothing else.
    ///
    /// People write phone numbers with spaces, brackets and dashes, and paste
    /// them from places that slip in a non-breaking space or a typographic
    /// character that looks like nothing at all. A field that reads
    /// "+1 555 010 0199" and says the number is wrong is wrong about phone
    /// numbers, not about the person typing. So take the digits and rebuild
    /// it, rather than refusing and making them guess which character
    /// offended.
    static func normalisedPhone(_ s: String) -> String {
        let digits = String(s.filter { $0.isASCII && $0.isNumber })
        return digits.isEmpty ? "" : "+" + digits
    }

    /// A plausible number once the punctuation is gone. E.164 allows fifteen
    /// digits; the short end is loose on purpose, because country plans vary
    /// and a wrong number is Telegram's to refuse, not this field's.
    static func isValidPhone(_ s: String) -> Bool {
        (6...15).contains(normalisedPhone(s).count - 1)
    }

    /// The Info.plist / JSON values arrive as a string or a number depending
    /// on who wrote them; `api_id` is written back as an int by the script.
    private static func string(_ v: Any?) -> String {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespaces) }
        if let n = v as? Int { return String(n) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }
}
