import Foundation

/// The licence on disk: one file holding the key exactly as the customer
/// pasted it.
///
/// A plain file rather than the Keychain, for three reasons. It is readable
/// after a restore from a backup or a migration to a new Mac, which is the
/// case a paying customer actually hits. It cannot prompt for a password.
/// And a Keychain item would have to be marked non-syncing on purpose
/// (CLOUD.md §14.2) to avoid cloning one purchase to every Mac the user owns
/// — a footgun this design simply does not have.
///
/// Storing the typed key rather than a decoded payload is deliberate too: the
/// signature is re-checked on every launch against the public key in *this*
/// build, so there is no cached "yes" for a later bug to trust.
public enum LicenceFile {

    /// Read whatever is there and say what it entitles this install to.
    ///
    /// **This function cannot fail.** No file, an empty file, a directory
    /// where the file should be, a file the user has no permission to read, a
    /// file full of binary rubbish, a key signed for somebody else's public
    /// key — every one of them returns `.unlicensed`, which is the state Moe
    /// has been in for its whole life and in which everything works. There is
    /// no throwing variant on purpose: a caller cannot write the `catch` that
    /// bricks the app if there is nothing to catch.
    public static func read(at url: URL, publicKey: Data) -> Entitlements {
        guard let data = try? Data(contentsOf: url),
              let typed = String(data: data, encoding: .utf8)
        else { return .unlicensed }
        return Entitlements.read(typed, publicKey: publicKey).0
    }

    /// Save a key the customer pasted. 0600, because it names them.
    ///
    /// Throws only so the UI can mention that the file did not save; the
    /// entitlement the caller already computed stays true either way. A
    /// read-only disk is not a reason to tell somebody they are unlicensed.
    public static func write(_ typed: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(typed.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Forget the key on this Mac. Never reports a problem: "remove it" has
    /// already succeeded if there is nothing there.
    public static func remove(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
