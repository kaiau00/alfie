import CryptoKit
import Foundation
import Testing
@testable import MoeLicence

/// Every keypair in this file is generated here, in memory, and thrown away
/// when the test ends. No real key — ours or anybody's — goes anywhere near
/// the repo; docs/RELEASING.md §1.5 is where the real one is described, and
/// describing it is all this project does.
private let us = Curve25519.Signing.PrivateKey()
private let someoneElse = Curve25519.Signing.PrivateKey()
private var ourPublicKey: Data { us.publicKey.rawRepresentation }

private func sample(
    id: String = "9f3a1c0055aa77b2",
    tier: Tier = .pro,
    buyer: String = "ada@example.com",
    issued: Date = Date(timeIntervalSince1970: 1_780_000_000),      // 2026-05-29
    updateWindowEnds: Date? = Date(timeIntervalSince1970: 1_811_000_000),   // 2027-05-23
    macs: Int = 2
) -> Licence {
    Licence(id: id, tier: tier, buyer: buyer, issued: issued,
            updateWindowEnds: updateWindowEnds, macs: macs)
}

/// Days, not seconds: the wire format stores days, so a round trip lands on
/// midnight UTC and comparing exact instants would fail for the wrong reason.
private func sameDay(_ a: Date?, _ b: Date?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return abs(a.timeIntervalSince(b)) < 86_400
}

// MARK: - The happy path

struct LicenceKeyTests {

    @Test func aValidKeyVerifiesAndCarriesEverythingBack() throws {
        let bought = sample()
        let key = LicenceKey.mint(bought, signedBy: us)

        let read = try LicenceKey.read(key, publicKey: ourPublicKey).get()
        #expect(read.id == bought.id)
        #expect(read.tier == .pro)
        #expect(read.buyer == "ada@example.com")
        #expect(read.macs == 2)
        #expect(sameDay(read.issued, bought.issued))
        #expect(sameDay(read.updateWindowEnds, bought.updateWindowEnds))
    }

    @Test func theKeyIsShapedLikeSomethingAPersonCanPaste() {
        let key = LicenceKey.mint(sample(), signedBy: us)

        #expect(key.hasPrefix("MOE01-"))
        // Groups of five, so it can be checked by eye and read down a phone.
        for group in key.split(separator: "-").dropFirst() {
            #expect(group.count <= 5)
        }
        // No 0/O or 1/I/l confusion is possible in the body: those
        // characters are not in the alphabet at all.
        #expect(!key.dropFirst(6).contains { "OILU".contains($0) })
        // Long enough to hold a 64-byte signature, short enough to paste.
        #expect(key.count < 280)
    }

    @Test func theCustomerCanRetypeItHowever() throws {
        let key = LicenceKey.mint(sample(), signedBy: us)
        let mangled = [
            key.lowercased(),                                        // shift key
            key.replacingOccurrences(of: "-", with: " "),            // spaces
            key.replacingOccurrences(of: "-", with: ""),             // no separators
            key.replacingOccurrences(of: "-", with: "\u{2013}"),     // "smart" dashes
            "  \(key)\n",                                            // a sloppy paste
        ]
        for m in mangled {
            #expect(LicenceKey.read(m, publicKey: ourPublicKey).isSuccess, "\(m.prefix(12))…")
        }
    }

    @Test func crockfordForgivesTheTwoSubstitutionsPeopleActuallyMake() throws {
        let key = LicenceKey.mint(sample(), signedBy: us)
        // Every 0 read as O and every 1 read as I: the classic retyping
        // mistake, and Crockford means it is not a mistake at all. The MOE01
        // prefix is left alone, which is exactly the case that would break if
        // the substitution were applied before the prefix was read.
        let body = key.dropFirst(6)
            .replacingOccurrences(of: "0", with: "O")
            .replacingOccurrences(of: "1", with: "I")
        #expect(LicenceKey.read("MOE01-" + body, publicKey: ourPublicKey).isSuccess)
    }

    @Test func everyTierSurvivesTheRoundTrip() throws {
        for tier in [Tier.pro, .lifetime, .monthly] {
            let read = try LicenceKey.read(LicenceKey.mint(sample(tier: tier), signedBy: us),
                                           publicKey: ourPublicKey).get()
            #expect(read.tier == tier)
        }
    }

    @Test func aLifetimeKeyHasNoWindowAtAll() throws {
        let read = try LicenceKey.read(LicenceKey.mint(sample(tier: .lifetime, updateWindowEnds: nil), signedBy: us),
                                       publicKey: ourPublicKey).get()
        #expect(read.updateWindowEnds == nil)
    }

    @Test func aNameWithAnAccentInItComesBackIntact() throws {
        let read = try LicenceKey.read(LicenceKey.mint(sample(buyer: "Ana Sofía Ñuñez"), signedBy: us),
                                       publicKey: ourPublicKey).get()
        #expect(read.buyer == "Ana Sofía Ñuñez")
    }
}

// MARK: - Every way a key can be wrong

struct BadKeyTests {

    @Test func nothingPastedIsNotAnAccusation() {
        #expect(LicenceKey.read("", publicKey: ourPublicKey).problem == .empty)
        #expect(LicenceKey.read("   \n ", publicKey: ourPublicKey).problem == .empty)
    }

    @Test func aTamperedPayloadFails() {
        // A determined edit: change a byte of the payload *and* fix the
        // checksum, so the only thing left standing between the customer and a
        // free licence is the signature.
        let key = LicenceKey.mint(sample(tier: .pro), signedBy: us)
        var blob = Base32.decode(key.dropFirst(6).replacingOccurrences(of: "-", with: ""))!

        blob[8] ^= 0x01                                  // somewhere in the fields
        let sum = CRC16.of(blob.prefix(blob.count - 2))  // and re-checksum it
        blob[blob.count - 2] = UInt8(sum >> 8)
        blob[blob.count - 1] = UInt8(sum & 0xFF)

        let forged = "MOE01-" + Base32.encode(blob)
        #expect(LicenceKey.read(forged, publicKey: ourPublicKey).problem == .notGenuine)
    }

    @Test func aKeySignedByTheWrongPrivateKeyFails() {
        let key = LicenceKey.mint(sample(), signedBy: someoneElse)
        #expect(LicenceKey.read(key, publicKey: ourPublicKey).problem == .notGenuine)
    }

    @Test func aMistypedKeyIsReportedAsMistypedNotAsForged() {
        // This is the case the whole checksum exists for. Every single
        // character of the body, changed to something else in the alphabet:
        // the customer must be told they slipped, never that they are a
        // forger. One in 65,536 of these gets through the CRC and lands on the
        // signature instead, so the assertion is "not accused", not "always
        // mistyped".
        let key = LicenceKey.mint(sample(), signedBy: us)
        let body = Array(key.dropFirst(6))
        var accused = 0

        for i in body.indices where body[i] != "-" {
            for replacement in ["2", "7", "K", "Z"] where String(body[i]) != replacement {
                var typo = body
                typo[i] = Character(replacement)
                let problem = LicenceKey.read("MOE01-" + String(typo), publicKey: ourPublicKey).problem
                #expect(problem != nil, "a one-character change must not verify")
                if problem == .notGenuine { accused += 1 }
            }
        }
        // Out of ~700 single-character typos, the CRC-16 should let through
        // roughly 0.01 of them. Anything above a handful means the checksum
        // is not doing its job.
        #expect(accused <= 2, "\(accused) typos were reported as forgeries")
    }

    @Test func aTruncatedOrPaddedPasteReadsAsMistyped() {
        let key = LicenceKey.mint(sample(), signedBy: us)
        #expect(LicenceKey.read(String(key.dropLast(6)), publicKey: ourPublicKey).problem == .looksMistyped)
        #expect(LicenceKey.read(key + "K7Z2W", publicKey: ourPublicKey).problem == .looksMistyped)
        #expect(LicenceKey.read("MOE01-HELLO", publicKey: ourPublicKey).problem == .looksMistyped)
    }

    @Test func somethingThatIsNotAKeyAtAllReadsAsMistyped() {
        for junk in ["hello", "MOE-01-ABCDE", "XYZ01-ABCDE", "MOEXX-ABCDE", "moe01"] {
            #expect(LicenceKey.read(junk, publicKey: ourPublicKey).problem == .looksMistyped, "\(junk)")
        }
    }

    @Test func aBuildWithNoPublicKeyRejectsRatherThanCrashes() {
        // build.sh omits the key from a plain checkout, exactly as it omits
        // Sparkle's. Verification then cannot succeed, and the thing it must
        // not do is trap.
        let key = LicenceKey.mint(sample(), signedBy: us)
        #expect(LicenceKey.read(key, publicKey: Data()).problem == .notGenuine)
        #expect(LicenceKey.read(key, publicKey: Data([1, 2, 3])).problem == .notGenuine)
    }

    @Test func anythingAtAllCanBePastedIntoTheField() {
        // The licence field is a text box on a screen anyone can reach, so
        // `read` has to be total over every string there is — the failures
        // that matter in a licence check are the ones that take the app down
        // with them. Nothing here may crash and nothing may hang.
        let hostile = [
            "MOE01-\u{0}\u{0}\u{0}",
            String(repeating: "MOE01-", count: 400),
            "MOE01-" + String(repeating: "Z", count: 5_000),
            "МОЕ01-ABCDE",                                  // Cyrillic М, О, Е
            "MOE01-\u{1F600}\u{1F600}",                    // emoji
            "MOE01-e\u{0301}e\u{0301}e\u{0301}",           // combining accents
            "MOE01-ßßßßß",                                  // uppercases to two characters each
            "MOE01-ǅǅǅǅǅ",                                   // titlecase
            "MOE\u{0661}\u{0661}-ABCDE",                    // Arabic-Indic digits
            "MOE01-ABCDE\u{FEFF}FGHJK",                     // a zero-width space from a PDF
        ]
        for junk in hostile {
            #expect(LicenceKey.read(junk, publicKey: ourPublicKey).problem != nil, "\(junk.prefix(20))")
        }
    }

    @Test func everyProblemHasSomethingSayableAndSaysNothingAboutCrypto() {
        let problems: [LicenceProblem] = [.empty, .looksMistyped, .needsNewerMoe(version: 9), .notGenuine]
        for problem in problems {
            let sentence = problem.sentence.lowercased()
            #expect(!sentence.isEmpty)
            for engineWord in ["ed25519", "signature", "curve", "checksum", "crc", "base32", "payload", "hash"] {
                #expect(!sentence.contains(engineWord), "\(problem) says \"\(engineWord)\"")
            }
        }
    }
}

// MARK: - The format has to survive its own future

struct FormatVersionTests {

    @Test func aKeyFromALaterMoeAsksForAnUpdateInsteadOfFailing() {
        // A v2 key: this build has never seen the layout and must not guess at
        // it, must not call it forged, and must not crash on it.
        let key = "MOE02-" + LicenceKey.mint(sample(), signedBy: us).dropFirst(6)
        #expect(LicenceKey.read(key, publicKey: ourPublicKey).problem == .needsNewerMoe(version: 2))

        let far = "MOE47-" + LicenceKey.mint(sample(), signedBy: us).dropFirst(6)
        #expect(LicenceKey.read(far, publicKey: ourPublicKey).problem == .needsNewerMoe(version: 47))
    }

    @Test func aFieldThisBuildHasNeverHeardOfIsSkipped() throws {
        // The forward-compatibility promise: adding a field in 2028 must not
        // invalidate a key sold in 2026, and must not stop a 2026 build from
        // reading the fields it does know. Minted here by hand at the byte
        // level, because `mint` can only write the fields that exist today.
        var signed = Data([1])                                  // format version 1
        signed.append(contentsOf: [1, 8] + [UInt8](repeating: 0xAB, count: 8))   // id
        signed.append(contentsOf: [2, 1, 1])                    // tier: pro
        signed.append(contentsOf: [3, 3] + Array("Ada".utf8))   // buyer
        signed.append(contentsOf: [99, 4, 0xDE, 0xAD, 0xBE, 0xEF])   // a tag from the future
        signed.append(contentsOf: [6, 1, 3])                    // macs, *after* the unknown tag

        let key = handMint(signed, signedBy: us)
        let licence = try LicenceKey.read(key, publicKey: ourPublicKey).get()

        #expect(licence.tier == .pro)
        #expect(licence.buyer == "Ada")
        // The field after the unknown one still parsed, which is the whole
        // point of length-prefixing every field.
        #expect(licence.macs == 3)
        // No window field at all reads as the generous case, not as expired.
        #expect(licence.updateWindowEnds == nil)
    }

    @Test func aTierThisBuildHasNeverHeardOfStillCounts() throws {
        var signed = Data([1])
        signed.append(contentsOf: [2, 1, 42])                   // a tier from 2029
        signed.append(contentsOf: [3, 3] + Array("Ada".utf8))

        let licence = try LicenceKey.read(handMint(signed, signedBy: us), publicKey: ourPublicKey).get()
        #expect(licence.tier == .unrecognised(42))
        #expect(Entitlements(licence: licence).isLicensed)
        // It is a real purchase we do not have a name for, so it gets
        // everything rather than nothing.
        #expect(Feature.allCases.allSatisfy { Entitlements(licence: licence).includes($0) })
    }

    @Test func aTruncatedFieldStopsTheParseWithoutLosingThePurchase() throws {
        // Only reachable if we mint something malformed ourselves — the
        // signature has already verified by this point. It must not throw the
        // purchase away over our own mistake.
        var signed = Data([1])
        signed.append(contentsOf: [2, 1, 2])                    // tier: lifetime
        signed.append(contentsOf: [3, 200] + Array("Ada".utf8)) // claims 200 bytes, carries 3

        let licence = try LicenceKey.read(handMint(signed, signedBy: us), publicKey: ourPublicKey).get()
        #expect(licence.tier == .lifetime)
        #expect(Entitlements(licence: licence).isLicensed)
    }

    @Test func aPrefixThatDisagreesWithThePayloadIsATypoNotAnAttack() {
        // The version is in the prefix *and* in the first signed byte, so the
        // prefix cannot be edited to make this build misread a later format.
        // When the two disagree, somebody retyped the front of the key — which
        // is a slip far more often than it is an attack, and is reported as one.
        var signed = Data([7])                                  // says version 7 inside
        signed.append(contentsOf: [2, 1, 1])
        #expect(LicenceKey.read(handMint(signed, signedBy: us), publicKey: ourPublicKey).problem == .looksMistyped)
    }

    /// Sign and wrap arbitrary body bytes, so a test can write a payload
    /// `mint` cannot.
    private func handMint(_ signed: Data, signedBy key: Curve25519.Signing.PrivateKey) -> String {
        var blob = signed
        blob.append(try! key.signature(for: signed))
        let sum = CRC16.of(blob)
        blob.append(UInt8(sum >> 8))
        blob.append(UInt8(sum & 0xFF))
        return "MOE01-" + Base32.encode(blob)
    }
}

// MARK: - Result sugar

private extension Result where Success == Licence, Failure == LicenceProblem {
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var problem: LicenceProblem? { if case .failure(let p) = self { return p }; return nil }
}
