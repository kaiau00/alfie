/// Compile-time switches for features that exist in the code but are not
/// offered to the person. One place, so "is this on?" has one answer and a
/// grep for `Features.` finds every seam.
enum Features {
    /// Dictation — "Typing by voice": hold a key in any app and the words
    /// land at the cursor, with the polish pass, the Voice › Typing tab,
    /// the Dictation sidebar section, the onboarding screen and the Brain ›
    /// "Tidy dictation with" row.
    ///
    /// **Off by the owner's decision of 2026-09-15 (docs/DEFAULTS.md row 4):
    /// "not a good quality product and overkill" for now.** Hidden, not
    /// deleted — it may be reworked later, and nothing in `MoeDictation` or
    /// `Sources/Moe/Dictation/` has been touched. Every seam is gated on this
    /// one constant: no key is registered (`Conductor.effectiveDictationKey`
    /// answers `.off` whatever config.json says), no tab, no section, no
    /// screen, no row, and the website and doc.md say nothing about it.
    /// Flip this to `true` and all of it comes back; the doc and the site
    /// copy are the only parts that would need a hand.
    static let dictation = false
}
