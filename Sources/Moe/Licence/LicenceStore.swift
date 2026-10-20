import Foundation
import MoeLicence

/// The app's one copy of "what did this person buy", and the only place that
/// knows where the key file and the public key live.
///
/// The verification itself is in `MoeLicence`, which has no idea what a bundle
/// or a home directory is — that split is what lets every branch of it be
/// tested. What is left here is plumbing, and the plumbing follows the same
/// rule as everything else: **nothing it can fail at is allowed to cost a
/// customer anything.** `entitlements` starts at `.unlicensed`, which is the
/// state every Moe that has ever shipped is in and in which everything works,
/// and no path below can leave the app worse off than that.
///
/// The public key is carried in Info.plist as `MoeLicencePublicKey`, exactly
/// as Sparkle's is carried as `SUPublicEDKey` (Updates.swift, build.sh). A
/// build from a plain checkout has neither, and then Moe simply has no
/// licensing in it — which is the correct behaviour for a developer build and
/// costs nobody anything, because nothing is gated either way.
@MainActor
final class LicenceStore: ObservableObject {
    static let shared = LicenceStore()

    /// What this install is entitled to. Read by the Settings pane; not read
    /// by any feature, on purpose — see `Entitlements`.
    @Published private(set) var entitlements: Entitlements = .unlicensed

    /// Why the last key the customer typed was not accepted, or nil. UI state
    /// only: it never means "switch something off".
    @Published private(set) var problem: LicenceProblem?

    /// Set when the key verified but the file would not save — a read-only
    /// disk, a full disk, a home directory somebody chowned. The licence is
    /// live for this run either way, and the pane says so rather than
    /// pretending the paste failed.
    @Published private(set) var couldNotSave = false

    /// True when this build carries no public key, so no key can be checked.
    /// The pane hides itself rather than showing a field that can only ever
    /// say no.
    var licensingIsConfigured: Bool { publicKey != nil }

    private let publicKey: Data?

    private init() {
        publicKey = Self.compiledPublicKey()
        load()
    }

    /// Read the key on disk. Called at init and after any change.
    func load() {
        guard let publicKey else {
            entitlements = .unlicensed
            return
        }
        entitlements = LicenceFile.read(at: Paths.licence, publicKey: publicKey)
        // The id, and nothing else. The key itself and the buyer's name are
        // never written to the log — a support bundle gets shared, and neither
        // of those is ours to spread around.
        Log.write("licence: \(entitlements.licence.map { "\($0.tier.name), id \($0.id.prefix(8))" } ?? "none")")
    }

    /// Accept a key the customer pasted. Returns whether it was taken.
    ///
    /// The order matters: the entitlement is set from the verified key
    /// *before* the file is written, so a disk that refuses the write costs
    /// them the persistence and not the purchase.
    @discardableResult
    func accept(_ typed: String) -> Bool {
        guard let publicKey else { return false }

        let (next, why) = Entitlements.read(typed, publicKey: publicKey)
        problem = why
        guard why == nil else { return false }

        entitlements = next
        couldNotSave = false
        do {
            try LicenceFile.write(typed, to: Paths.licence)
        } catch {
            couldNotSave = true
            // Deliberately without the key or the error's file path, both of
            // which carry it.
            Log.write("licence: verified but could not be saved to disk")
        }
        return true
    }

    /// Forget the key on this Mac. The customer still owns what they bought;
    /// this is the "I'm selling this Mac" button, not a punishment.
    func forget() {
        LicenceFile.remove(at: Paths.licence)
        entitlements = .unlicensed
        problem = nil
        couldNotSave = false
    }

    /// The 32-byte Ed25519 public key this build was compiled with, or nil.
    ///
    /// Blank counts as absent for the same reason it does in Updates.swift: a
    /// release built with the environment variable unset must behave like a
    /// build that never had licensing, not like a build whose licensing is
    /// broken.
    private static func compiledPublicKey() -> Data? {
        let raw = TestHooks.env("MOE_LICENCE_PUBLIC_KEY")
            ?? (Bundle.main.object(forInfoDictionaryKey: "MoeLicencePublicKey") as? String)
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let key = Data(base64Encoded: trimmed), key.count == 32
        else { return nil }
        return key
    }
}
