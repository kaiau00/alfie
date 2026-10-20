import Foundation

/// What this install is entitled to. The one thing the rest of the app asks.
///
/// # The seam
///
/// A feature that is sold asks `entitlements.includes(.someFeature)` and gets
/// a `Bool`. **Nothing in Moe asks today, and nothing is gated today.**
/// Everything that shipped before this change still ships to everybody; the
/// switch-flipping is a product decision that has not been made. What exists
/// here is the mechanism and nothing else.
///
/// # Why the shape is this shape
///
/// The one unforgivable outcome is locking out somebody who paid, so the type
/// is built to make that hard rather than merely to avoid it:
///
/// - **There is no failure state.** `Entitlements` has exactly two
///   constructors, and the one that reads a key returns `.unlicensed` for
///   every kind of bad input. Nothing throws out of here, so no caller can
///   forget a `catch` and turn a missing file into a dead app.
/// - **`includes(_:)` takes no date.** It is not possible to write a
///   clock-dependent feature gate through this API, which means no clock — set
///   backwards, set forwards, or never set — can take a feature away. The
///   update window is reachable only through `updatesCover(buildReleasedOn:)`,
///   which is about *builds*, not about features.
/// - **A feature nobody is selling answers `true` for everyone.** See
///   `Feature.isSold`. A gate added to a free feature by accident cannot lock
///   anybody out, because the licence is never consulted for it.
/// - **A tier we do not recognise counts as licensed.** A future SKU read by
///   an older Moe is a real purchase, and the safe direction is to honour it.
public struct Entitlements: Equatable, Sendable {

    /// The purchase, or `nil`. `nil` covers every way this can go wrong —
    /// nothing was ever bought, the file is missing, the file is unreadable,
    /// the key is corrupt, this build carries no public key — because from the
    /// app's point of view they are the same situation and they all mean
    /// "everything still works, nothing extra is on".
    public let licence: Licence?

    /// An install with no key. The default, and the state every error lands in.
    public static let unlicensed = Entitlements(licence: nil)

    public init(licence: Licence?) {
        self.licence = licence
    }

    /// Read a pasted or stored key. Any problem at all yields `.unlicensed`
    /// plus the reason, so a caller that ignores the reason still gets an app
    /// that works.
    public static func read(_ typed: String, publicKey: Data) -> (Entitlements, LicenceProblem?) {
        switch LicenceKey.read(typed, publicKey: publicKey) {
        case .success(let licence): return (Entitlements(licence: licence), nil)
        case .failure(let problem): return (.unlicensed, problem)
        }
    }

    public var isLicensed: Bool { licence != nil }

    /// The SKU, for showing. `nil` when unlicensed.
    public var tier: Tier? { licence?.tier }

    // MARK: - The seam

    /// Whether this install may use `feature`.
    ///
    /// This is the whole seam, and it is currently unused on purpose. When a
    /// feature does start being sold, the call reads like this — and this is
    /// the one worked example, deliberately left as a comment rather than as
    /// code, because turning it into code would gate something:
    ///
    /// ```swift
    /// // In MeetingsPane, when the meeting library becomes a Pro feature:
    /// if LicenceStore.shared.entitlements.includes(.meetingLibrary) {
    ///     showLibrary()
    /// } else {
    ///     showWhatProAdds()      // an offer, never an error, and never a
    ///                            // dialog in the middle of a meeting
    /// }
    /// ```
    ///
    /// Note what is *not* in that example: no date, no network call, no
    /// "verifying…" state, and no branch that can leave the app unusable. The
    /// worst case is that a customer sees an offer they have already paid for,
    /// which is a support email; the other direction is a refund.
    public func includes(_ feature: Feature) -> Bool {
        // The short-circuit that makes an accidental gate harmless: if the
        // feature is not being sold, the answer is yes and the licence is
        // never consulted. Today every feature takes this path.
        guard feature.isSold else { return true }
        return isLicensed
    }

    // MARK: - The update window

    /// Whether a build released on `releaseDate` is covered by what this
    /// customer bought.
    ///
    /// **A closed window takes nothing away.** The customer keeps every
    /// version they already have, with everything it does, forever — this is
    /// the BetterTouchTool/CleanShot shape from CLOUD.md §14.5, and modelling
    /// it any other way would be selling a subscription while calling it a
    /// purchase. All this answers is whether a *newer* build should treat the
    /// key as covering itself.
    ///
    /// It must never be used to stop an installed build from running, and it
    /// must never be put in front of Sparkle: an app that withholds security
    /// fixes from lapsed customers is doing something worse than losing the
    /// revenue, and — per the Logitech outage in CLOUD.md §14.2 — a licence
    /// bug that blocks the updater is a bug that can never be fixed remotely.
    public func updatesCover(buildReleasedOn releaseDate: Date) -> Bool {
        guard let licence else { return false }
        guard let ends = licence.updateWindowEnds else { return true }   // lifetime
        return releaseDate <= ends
    }

    /// Where the update window stands, for showing in Settings.
    ///
    /// Every clock question is resolved toward the customer:
    ///
    /// - A Mac whose clock is behind the day we minted the key has a clock
    ///   that is wrong, not a licence that is finished, so the window reads as
    ///   open. This is the "clock set backwards does not revoke anybody" rule,
    ///   and it is here rather than in the caller so there is one place to get
    ///   it right.
    /// - No end date at all is the lifetime SKU, and reads as never closing.
    public func updateWindow(asOf now: Date = Date()) -> UpdateWindow? {
        guard let licence else { return nil }
        guard let ends = licence.updateWindowEnds else { return .neverEnds }
        if now < licence.issued { return .open(until: ends) }
        return now <= ends ? .open(until: ends) : .closed(since: ends)
    }
}

// MARK: - Features

/// The things that could be sold, from CLOUD.md §14.5.
///
/// Named by what they do, never by the engine behind them — "high accuracy",
/// not the model's name (PRODUCT.md §7).
public enum Feature: String, CaseIterable, Sendable {
    /// Meeting *capture* is free forever and is not on this list. The library,
    /// the cross-meeting search, the export.
    case meetingLibrary
    /// Per-app tone and vocabulary, custom rewrite prompts, history search.
    case deeperDictation
    /// The slower, more accurate transcription mode.
    case highAccuracyTranscription
    /// More voices, per-app and per-contact assignment, prosody control.
    case voiceControl
    /// The CLI, webhooks, shortcuts, scripting.
    case automation

    /// Whether this feature is behind the licence *in the shipping build*.
    ///
    /// Every case is `false`, and that is the point of this change: the
    /// mechanism exists, nothing uses it. Flipping one of these to `true` is
    /// the product decision, and `MoeLicenceTests` asserts they are all
    /// `false` so that it has to be a decision rather than a slip.
    public var isSold: Bool { false }
}

// MARK: - Update window

/// How much longer new builds are included. Not an expiry — see
/// `Entitlements.updatesCover(buildReleasedOn:)`.
public enum UpdateWindow: Equatable, Sendable {
    /// The lifetime SKU.
    case neverEnds
    case open(until: Date)
    /// Newer builds are no longer included. Everything already installed
    /// keeps working, and updates still install — they just aren't part of
    /// what was paid for.
    case closed(since: Date)

    public var isOpen: Bool {
        if case .closed = self { return false }
        return true
    }
}
