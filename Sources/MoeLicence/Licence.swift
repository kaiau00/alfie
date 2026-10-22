import Foundation

/// What a customer bought, as it comes back out of the key they pasted.
///
/// Everything here was signed by us, so by the time a `Licence` exists the
/// bytes are ours and nobody edited them. Nothing on this type is a
/// permission: there is deliberately no `isValid`, no `expiresAt`, and no way
/// to ask a `Licence` whether the app may run. Those questions live on
/// `Entitlements`, which answers them in the customer's favour by
/// construction. See CLOUD.md §14.2, "fail toward the customer".
public struct Licence: Equatable, Sendable {

    /// The handle support quotes back. Eight random bytes, shown as hex.
    ///
    /// It is here so that a revocation list could be added later without
    /// re-issuing a single key sold before it existed — a refunded licence
    /// would be named by this id. Nothing in this change looks it up, and
    /// nothing in this change contacts a server.
    public let id: String

    /// Which SKU. See CLOUD.md §14.5.
    public let tier: Tier

    /// Who bought it — a name or an email, exactly as it was sold. Shown back
    /// to the customer so they can see the key is theirs. Never logged.
    public let buyer: String

    /// When we minted it.
    public let issued: Date

    /// The last day whose builds this purchase includes. `nil` means the
    /// window never closes (the lifetime SKU).
    ///
    /// This is *not* an expiry. A closed window takes nothing away — see
    /// `Entitlements.updatesCover(buildReleasedOn:)`.
    public let updateWindowEnds: Date?

    /// How many Macs it was sold for. A number to show, not a fence: the
    /// device count is a price ladder (CLOUD.md §14.2) and Moe does not count
    /// installs, which would need a server it does not have.
    public let macs: Int

    public init(id: String, tier: Tier, buyer: String, issued: Date,
                updateWindowEnds: Date?, macs: Int) {
        self.id = id
        self.tier = tier
        self.buyer = buyer
        self.issued = issued
        self.updateWindowEnds = updateWindowEnds
        self.macs = macs
    }
}

// MARK: - Tier

/// The SKUs of CLOUD.md §14.5, plus the case that keeps an old app working
/// when we invent a new one.
public enum Tier: Equatable, Sendable {
    /// $79 once, a year of updates.
    case pro
    /// $199 once, updates forever.
    case lifetime
    /// $9/month; the window is the paid-up month and re-issues on renewal.
    case monthly
    /// A tier this build has never heard of, carried through rather than
    /// rejected. An app from 2027 selling a "team" tier must not turn a 2028
    /// key into an error message — it is a real, signed purchase, so it counts
    /// as licensed and gets everything. Erring the other way would lock out
    /// somebody who paid us more.
    case unrecognised(UInt8)

    /// The name to show the customer.
    public var name: String {
        switch self {
        case .pro:       return "Alfie Pro"
        case .lifetime:  return "Alfie Pro Lifetime"
        case .monthly:   return "Alfie Pro, monthly"
        // Deliberately vague rather than wrong: we do not know what this build
        // is looking at, and "Moe Pro" is the true part of the answer.
        case .unrecognised: return "Alfie Pro"
        }
    }

    var code: UInt8 {
        switch self {
        case .pro: return 1
        case .lifetime: return 2
        case .monthly: return 3
        case .unrecognised(let c): return c
        }
    }

    init(code: UInt8) {
        switch code {
        case 1: self = .pro
        case 2: self = .lifetime
        case 3: self = .monthly
        default: self = .unrecognised(code)
        }
    }
}

// MARK: - What went wrong

/// Why a pasted key did not turn into a `Licence`.
///
/// The cases exist to be *said out loud* to a customer, which is why they
/// separate "you mistyped it" from "this is not one of ours". Getting that
/// distinction wrong is the difference between a five-second fix and a support
/// thread that starts with an accusation.
public enum LicenceProblem: Error, Equatable, Sendable {
    /// Nothing was pasted.
    case empty
    /// The characters or the checksum don't add up: a dropped character, a
    /// half-copied line, a key typed by hand. Almost always a typo, and it is
    /// checked *before* the signature so that it reads as one.
    case looksMistyped
    /// A well-formed key in a format version this build predates. The customer
    /// needs a newer Moe, not a new key.
    case needsNewerMoe(version: Int)
    /// Checksum fine, signature not ours. Either it was edited on purpose or
    /// it was minted by somebody else.
    case notGenuine

    /// One sentence, for a person, in the app's voice. No crypto words:
    /// PRODUCT.md §7 — never expose the engine, and "Ed25519" is an engine.
    public var sentence: String {
        switch self {
        case .empty:
            return "Paste your licence key here."
        case .looksMistyped:
            return "That key looks mistyped — a character is off somewhere. Copying the whole line again usually fixes it."
        case .needsNewerMoe:
            return "That key is newer than this copy of Alfie. Update Alfie and try again."
        case .notGenuine:
            return "That key isn't one of ours. If you bought Alfie and this is the key you were sent, send us the first few characters and we'll sort it out."
        }
    }
}
