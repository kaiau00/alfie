import CryptoKit
import Foundation

/// The licence key itself: the short string a customer pastes in, and the
/// arithmetic that turns it back into a `Licence`.
///
/// # The wire format
///
/// ```
/// MOE01-8Z4KT-3M9QW-…-…-XT2R
/// ^^^^^ ^^^^^^^^^^^^^^^^^^^^
/// │     Crockford base32, hyphenated every five characters
/// └───── the format version, always two digits, so a key from a later
///        Moe is recognisable as one without decoding it
/// ```
///
/// The version is two digits rather than however many it needs, because
/// people strip the hyphens. `MOE1` followed by a body starting `040GH` is
/// indistinguishable from version 1040; a fixed width ends the ambiguity
/// without making the separator load-bearing.
///
/// The bytes underneath, in order:
///
/// | Bytes | What |
/// |---|---|
/// | 1 | format version, again — see below |
/// | n | fields, each `[tag:1][length:1][value:length]` |
/// | 64 | Ed25519 signature over everything above it |
/// | 2 | CRC-16/CCITT over everything above *it*, including the signature |
///
/// Five decisions, and why each one:
///
/// **Ed25519, verified against a public key compiled into the app.** Same
/// primitive Sparkle already uses for updates (docs/RELEASING.md §1.4), so
/// this repo has one kind of signing key to look after rather than two kinds.
/// Verification is arithmetic on 32 bytes we ship — it needs no network, ever,
/// which is the whole point (CLOUD.md §14.2).
///
/// **Crockford base32, not base64.** Base64 is 20% shorter and much worse to
/// read down a phone line or retype off a printed invoice: it is
/// case-sensitive, and it contains all four of `0O1l`. Crockford's alphabet
/// drops `I`, `L`, `O` and `U`, is case-insensitive, and lets the decoder
/// silently fix the two substitutions people actually make (`O`→`0`, `I`/`L`
/// →`1`). A key that survives being read aloud is worth 20% more characters.
///
/// **A CRC-16, checked before the signature.** Without it every fumbled paste
/// comes back "this key isn't genuine", which accuses a paying customer of
/// forgery over a missing character. With it, one wrong character is
/// overwhelmingly likely to fail the checksum first and be reported as what it
/// is. The signature is what makes a key unforgeable; the checksum is what
/// makes a typo *readable*.
///
/// **Tag-length-value fields rather than JSON.** Two reasons and the second is
/// the important one. It is about a third the size, which is the difference
/// between four hyphenated lines and six. And an older Moe skips a tag it has
/// never seen instead of choking on it — so adding a field in 2028 does not
/// invalidate a single key sold in 2026. That property is why the payload is
/// versioned in two places: the prefix, so a genuinely incompatible future
/// format announces itself without being parsed, and the first signed byte, so
/// the prefix cannot be edited to make an old app misread a new key.
///
/// **The checksum covers the signature, and the signature does not cover the
/// checksum.** In that order the two jobs stay separate: the checksum's job is
/// "did this arrive intact", so it has to see every byte that was typed; the
/// signature's job is "did we write this", and a typo-detector is not
/// something we assert.
///
/// Nothing here is secret. The public key ships in the app, the format is
/// documented above, and neither fact weakens anything — an unforgeable key
/// needs a private key we hold, and that is the only secret in the design.
public enum LicenceKey {

    /// Days are counted from here, so a date fits in two bytes and the format
    /// stays good until 2199.
    static let epoch = Date(timeIntervalSince1970: 1_577_836_800)   // 2020-01-01 UTC

    /// The only format this build can read.
    static let version = 1

    private static let signatureBytes = 64
    private static let checksumBytes = 2

    // MARK: - Reading a key

    /// Turn a pasted string into the purchase it stands for.
    ///
    /// `publicKey` is the 32-byte Ed25519 public key this build was compiled
    /// with. Passing it in rather than reading it from the bundle is what
    /// makes this whole file testable without a real keypair anywhere near the
    /// repo.
    public static func read(_ typed: String, publicKey: Data) -> Result<Licence, LicenceProblem> {
        var rest = Substring(squeeze(typed))
        guard !rest.isEmpty else { return .failure(.empty) }

        // The prefix is read first and without decoding anything, so that a
        // key from a Moe we have not shipped yet is reported as "update Moe"
        // rather than as a corrupt string.
        guard rest.hasPrefix("MOE") else { return .failure(.looksMistyped) }
        rest = rest.dropFirst(3)
        let digits = rest.prefix(2)
        guard digits.count == 2, digits.allSatisfy(\.isNumber), let claimedVersion = Int(digits) else {
            return .failure(.looksMistyped)
        }
        guard claimedVersion == version else { return .failure(.needsNewerMoe(version: claimedVersion)) }

        let body = rest.dropFirst(2)
        guard let blob = Base32.decode(body),
              blob.count >= 1 + signatureBytes + checksumBytes
        else { return .failure(.looksMistyped) }

        let checksummed = blob.prefix(blob.count - checksumBytes)
        let carried = UInt16(blob[blob.count - 2]) << 8 | UInt16(blob[blob.count - 1])
        guard CRC16.of(checksummed) == carried else { return .failure(.looksMistyped) }

        let signed = checksummed.prefix(checksummed.count - signatureBytes)
        let signature = checksummed.suffix(signatureBytes)

        // The version is inside the signature as well as in the prefix. A
        // mismatch means somebody retyped the prefix, which is a typo far more
        // often than it is an attack, so it is reported as one.
        guard let first = signed.first, Int(first) == claimedVersion else {
            return .failure(.looksMistyped)
        }

        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              key.isValidSignature(Data(signature), for: Data(signed))
        else { return .failure(.notGenuine) }

        return .success(licence(fromSignedBody: Data(signed.dropFirst())))
    }

    // MARK: - Writing a key
    //
    // Moe never calls this — it has no private key and never will. It is here
    // because the format has to be written down exactly once, and a decoder
    // that has never been run against its own encoder is a decoder nobody has
    // tested. scripts/make-licence.py is the tool that actually mints keys and
    // it implements this same layout; the tests hold the two to each other.

    /// Sign a licence and render it as a key string.
    public static func mint(_ licence: Licence, signedBy privateKey: Curve25519.Signing.PrivateKey) -> String {
        var signed = Data([UInt8(version)])
        signed.append(contentsOf: body(of: licence))

        let signature = (try? privateKey.signature(for: signed)) ?? Data()
        var blob = signed
        blob.append(signature)
        let sum = CRC16.of(blob)
        blob.append(UInt8(sum >> 8))
        blob.append(UInt8(sum & 0xFF))

        return String(format: "MOE%02d-", version) + group(Base32.encode(blob))
    }

    // MARK: - Fields

    private enum Tag: UInt8 {
        case id = 1
        case tier = 2
        case buyer = 3
        case issued = 4
        case updateWindowEnds = 5
        case macs = 6
    }

    /// `0xFFFF` in the update-window field means "never ends" — the lifetime
    /// SKU. A sentinel rather than an absent field so that the generous case
    /// is something we said, not something that fell out of a gap.
    static let neverEnds: UInt16 = 0xFFFF

    private static func body(of licence: Licence) -> [UInt8] {
        var out: [UInt8] = []
        func field(_ tag: Tag, _ value: [UInt8]) {
            out.append(tag.rawValue)
            out.append(UInt8(min(value.count, 255)))
            out.append(contentsOf: value.prefix(255))
        }
        func days(_ date: Date) -> [UInt8] {
            let d = UInt16(max(0, min(Double(UInt16.max - 1), (date.timeIntervalSince(epoch) / 86_400).rounded(.down))))
            return [UInt8(d >> 8), UInt8(d & 0xFF)]
        }

        field(.id, hexBytes(licence.id))
        field(.tier, [licence.tier.code])
        field(.buyer, Array(licence.buyer.utf8))
        field(.issued, days(licence.issued))
        field(.updateWindowEnds, licence.updateWindowEnds.map(days) ?? [UInt8(neverEnds >> 8), UInt8(neverEnds & 0xFF)])
        field(.macs, [UInt8(clamping: licence.macs)])
        return out
    }

    /// Read the fields back.
    ///
    /// This cannot fail, and that is deliberate. By the time it runs the
    /// signature has already verified, so these bytes are exactly the bytes we
    /// signed — a malformed field here would be *our* mistake, and the last
    /// thing it should do is turn a real purchase into an error message on the
    /// customer's screen. Unknown tags are skipped, a truncated field ends the
    /// parse, and anything missing falls back to the reading most generous to
    /// whoever paid.
    private static func licence(fromSignedBody bytes: Data) -> Licence {
        var fields: [UInt8: [UInt8]] = [:]
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let tag = bytes[i]
            let lengthIndex = bytes.index(after: i)
            guard lengthIndex < bytes.endIndex else { break }
            let length = Int(bytes[lengthIndex])
            let start = bytes.index(after: lengthIndex)
            guard let end = bytes.index(start, offsetBy: length, limitedBy: bytes.endIndex) else { break }
            fields[tag] = Array(bytes[start..<end])
            i = end
        }

        func u16(_ tag: Tag) -> UInt16? {
            guard let v = fields[tag.rawValue], v.count == 2 else { return nil }
            return UInt16(v[0]) << 8 | UInt16(v[1])
        }
        func date(_ tag: Tag) -> Date? {
            u16(tag).map { epoch.addingTimeInterval(Double($0) * 86_400) }
        }

        let windowDays = u16(.updateWindowEnds)
        return Licence(
            id: (fields[Tag.id.rawValue] ?? []).map { String(format: "%02x", $0) }.joined(),
            tier: Tier(code: fields[Tag.tier.rawValue]?.first ?? 0),
            buyer: String(decoding: fields[Tag.buyer.rawValue] ?? [], as: UTF8.self),
            // Absent means "we have no idea when this was minted", and the one
            // thing `issued` is used for is noticing a clock that is behind it.
            // distantPast makes that check say "the clock is fine", which is
            // the answer that takes nothing away.
            issued: date(.issued) ?? .distantPast,
            updateWindowEnds: (windowDays == nil || windowDays == neverEnds) ? nil : date(.updateWindowEnds),
            macs: Int(fields[Tag.macs.rawValue]?.first ?? 1)
        )
    }

    // MARK: - String shapes

    /// Upper-case, with everything a mail client or a PDF might have put
    /// between the groups taken out: spaces, newlines, hyphens, and the en and
    /// em dashes that "smart" text substitution turns hyphens into.
    ///
    /// The `O`→`0` and `I`/`L`→`1` forgiveness happens in `Base32.decode`, not
    /// here, because the `O` in `MOE` is a real letter and normalising it away
    /// would leave the prefix unrecognisable.
    private static func squeeze(_ typed: String) -> String {
        typed.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "\u{2013}" && $0 != "\u{2014}" }
    }

    /// Hyphen every five characters. Groups are what make a long key
    /// checkable by eye and retypeable without losing your place.
    private static func group(_ s: String) -> String {
        stride(from: 0, to: s.count, by: 5).map {
            String(s.dropFirst($0).prefix(5))
        }.joined(separator: "-")
    }

    private static func hexBytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var pair = ""
        for ch in hex where ch.isHexDigit {
            pair.append(ch)
            if pair.count == 2 {
                out.append(UInt8(pair, radix: 16) ?? 0)
                pair = ""
            }
        }
        return out
    }
}

// MARK: - Crockford base32

/// Douglas Crockford's base32: no `I`, `L`, `O` or `U`, case-insensitive.
///
/// `U` is left out of the alphabet on purpose (it is what keeps a random key
/// from spelling something regrettable), so a `U` in a pasted key is a typo
/// for `V` and the decoder says so rather than guessing.
enum Base32 {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Every character that means something, in both cases, built once.
    ///
    /// A dictionary rather than `alphabet.firstIndex(of: Character(ch.uppercased()))`,
    /// which is how this was first written and which can *trap*: uppercasing
    /// one character does not always give back one character, and
    /// `Character(_: String)` is a runtime error on anything else. Today
    /// `squeeze` happens to uppercase the whole string first, so nothing
    /// reaches it in that state — but that is a coupling between two
    /// functions holding a crash shut, in the one place in Moe where a person
    /// can paste literally anything. A total lookup does not need the
    /// coupling to be true.
    static let values: [Character: Int] = {
        var table: [Character: Int] = [:]
        for (i, ch) in alphabet.enumerated() {
            table[ch] = i
            for lower in ch.lowercased() { table[lower] = i }
        }
        // Crockford's forgiveness: the two substitutions people make every
        // time they retype a key.
        for (ch, value) in [("O", 0), ("o", 0), ("I", 1), ("i", 1), ("L", 1), ("l", 1)] {
            table[Character(ch)] = value
        }
        return table
    }()

    static func encode(_ data: Data) -> String {
        var out = ""
        var buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    /// `nil` on any character outside the alphabet — the caller reports that
    /// as a mistyped key, which is what it nearly always is.
    ///
    /// `O` is read as zero and `I` and `L` as one, per Crockford. Those are
    /// the two substitutions people make every time, and silently getting them
    /// right is most of the reason for choosing this alphabet.
    static func decode<S: StringProtocol>(_ s: S) -> Data? {
        var out = Data()
        var buffer = 0, bits = 0
        for ch in s {
            guard let value = values[ch] else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        // The encoder always pads with zeros, so anything else in the last
        // character's spare bits is a character that was changed after we
        // wrote it. Checking them costs nothing and catches the one typo the
        // checksum cannot see: an edit to the final character that lands only
        // in the padding would otherwise decode to the very same bytes.
        guard buffer & ((1 << bits) - 1) == 0 else { return nil }
        return out
    }
}

// MARK: - CRC-16

/// CRC-16/CCITT-FALSE (polynomial 0x1021, initial 0xFFFF).
///
/// Chosen over a truncated hash because its error-detection is a guarantee
/// rather than an average: it catches every single-character substitution and
/// every burst shorter than itself, which is the exact shape of the mistakes
/// people make copying a key.
enum CRC16 {
    static func of<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
