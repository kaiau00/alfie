import Foundation

/// The wake word's second stage (PLAN.md Step 1.5; research-wakeword.md):
/// when the head fires, the local recogniser reads the two seconds it fired
/// on, and Moe wakes only if the name is in them.
///
/// The head alone cannot be both sensitive and safe. At its shipped 0.95
/// it hears the owner 63.6 % of the time (14/22 held-out clips) and still
/// fires on 8 of 30 confusables; "how are you" scored 0.83 and a real wake
/// 0.76–0.92, so no threshold separates them. A recogniser can: it reads
/// "how are you" as those words. So the head's threshold comes down to
/// catch the owner, and the recogniser turns away what that lets in.
public enum WakeConfirm {

    /// How the recogniser writes the name itself: one syllable, /moʊ/, with
    /// nothing after the vowel. "Molly", "Mona", "Moses", "mode", "mom" are
    /// the confusables the head fires on and the recogniser writes exactly —
    /// they are what this stage exists to turn away (measured on the Inworld
    /// confusable set, 2026-09-23: 60 of the head's 117 false fires there
    /// were written as one of those).
    static let nameTokens: Set<String> = ["mo", "moe", "mow", "moi"]
    /// Real words that end in the name's letters.
    static let wordsEndingInMo: Set<String> = ["demo", "memo", "promo", "limo", "sumo", "primo", "gizmo", "ammo"]

    /// Is the name in what the recogniser heard? The name on its own ("Hey
    /// Mo.", "Ei moe"), or run into whatever came before it ("Hemo", "Amo",
    /// "Nemo", "K-mo" — a short word ending in the name). These are how the
    /// local recogniser wrote a real "Hey Moe" on the owner's 65 recordings
    /// and 322 Inworld voices; the one real word among them, "Amount" —
    /// "a Moe" run together — counts only when it is all that was heard.
    public static func heardTheName(_ transcript: String, spotter: WakeSpotter) -> Bool {
        let words = TurnPolicy.words(transcript)
        guard !words.isEmpty else { return false }
        if words == ["amount"] { return true }
        for w in words {
            if nameTokens.contains(w) { return true }
            let letters = w.replacingOccurrences(of: "-", with: "")
            guard letters.count <= 6, !wordsEndingInMo.contains(letters) else { continue }
            for token in nameTokens where letters.hasSuffix(token) {
                let prefix = letters.dropLast(token.count)
                if !prefix.isEmpty, prefix.count <= 3 { return true }
            }
        }
        return false
    }

    /// The head's policy when every hit is confirmed: the same run length and
    /// timings, the threshold down to `threshold` (never up — a per-Mac
    /// calibration lower than it stands).
    public static func headPolicy(_ base: WakePolicy, confirming: Bool, threshold: Float) -> WakePolicy {
        guard confirming, threshold < base.threshold else { return base }
        return base.withThreshold(threshold)
    }
}
