import Contacts
import Foundation
import MoeDictation

/// Feeds the names in the user's Contacts into the dictation vocabulary
/// (PRODUCT.md §4.1), so "shavon" comes out as "Siobhan" without anyone
/// typing every colleague into vocabulary.txt.
///
/// Off by default. Reading Contacts is a TCC prompt, and the one-click
/// principle says Moe never prompts for anything the user didn't just ask
/// for — so access is requested only when "Use my Contacts for names" is
/// switched on, and then lazily, on the first refresh.
///
/// What is kept is decided by `ContactTerms.filter` (pure, tested); this
/// file only fetches and caches. The cache is `~/.moe/vocabulary-contacts.txt`,
/// mode 0600, in the vocabulary file syntax, refreshed once a day, and
/// deleted when the setting is switched off. `Vocabulary.shared` reads it as
/// its lowest-priority source, so the user's own lines always win.
enum ContactsVocabulary {

    static let refreshInterval: TimeInterval = 24 * 60 * 60

    static var cacheURL: URL { Config.homeDir.appendingPathComponent(Vocabulary.contactsFile) }

    private static let queue = DispatchQueue(label: "moe.contacts-vocabulary", qos: .utility)

    /// Apply the setting: on, refresh the cache if it is a day old or
    /// missing (asking for access if needed); off, delete the cache so the
    /// names stop being used at once. Never blocks the caller.
    static func sync(enabled: Bool) {
        queue.async {
            if enabled {
                refreshIfStale()
            } else {
                removeCache()
            }
        }
    }

    /// Fetch now regardless of age; what the settings toggle uses so the
    /// user sees the effect (and the permission prompt) when they flip it.
    static func refreshNow() {
        queue.async { refresh() }
    }

    private static func refreshIfStale() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        if let mtime, Date().timeIntervalSince(mtime) < refreshInterval { return }
        refresh()
    }

    private static func refresh() {
        // Without the usage string (a bare `swift run` binary has no
        // Info.plist) TCC kills the process on the first Contacts call
        // rather than prompting. build.sh writes the key.
        guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil else {
            Log.write("contacts vocabulary: skipped, no NSContactsUsageDescription in Info.plist (run the built app)")
            return
        }
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            break
        case .notDetermined:
            // Blocks this utility queue, not the UI, until the user answers.
            let granted = requestAccess(store)
            guard granted else {
                Log.write("contacts vocabulary: access declined")
                return
            }
        case .denied, .restricted:
            Log.write("contacts vocabulary: access denied in System Settings › Privacy › Contacts")
            return
        @unknown default:
            return
        }

        var fields: [String] = []
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey,
                    CNContactNicknameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        do {
            // Names first, organisations after: `ContactTerms.filter` keeps
            // first-seen order, so if the cap bites it is companies that go.
            var orgs: [String] = []
            try store.enumerateContacts(with: request) { contact, _ in
                fields.append(contact.givenName)
                fields.append(contact.middleName)
                fields.append(contact.familyName)
                fields.append(contact.nickname)
                if !contact.organizationName.isEmpty { orgs.append(contact.organizationName) }
            }
            fields += orgs
        } catch {
            Log.write("contacts vocabulary: fetch failed (\(error.localizedDescription))")
            return
        }

        // Everyday words are dropped: a contact called "Will" must not
        // capitalise every "will" the user says.
        let terms = ContactTerms.filter(fields, common: .system)
        write(terms)
        // The count only: which names is nobody's business but the user's.
        Log.write("contacts vocabulary: cached \(terms.count) names")
    }

    private static func requestAccess(_ store: CNContactStore) -> Bool {
        let done = DispatchSemaphore(value: 0)
        var granted = false
        store.requestAccess(for: .contacts) { ok, _ in
            granted = ok
            done.signal()
        }
        done.wait()
        return granted
    }

    private static func write(_ terms: [String]) {
        let header = """
        # Names from Contacts, refreshed by Alfie about once a day. Don't edit —
        # put your own spellings in vocabulary.txt, which wins over this file.

        """
        let body = header + terms.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: Config.homeDir, withIntermediateDirectories: true)
            try body.write(to: cacheURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            Log.write("contacts vocabulary: could not write cache (\(error.localizedDescription))")
        }
    }

    private static func removeCache() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        try? FileManager.default.removeItem(at: cacheURL)
        Log.write("contacts vocabulary: cache removed")
    }
}
