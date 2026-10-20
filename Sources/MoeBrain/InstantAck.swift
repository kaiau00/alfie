import Foundation

/// The first thing you hear, said by this machine before the brain has been
/// asked anything at all.
///
/// Measured on the live gateway (2026-09-03, this Mac, warm session, nothing
/// else running): a persistent `claude -p` child answers its first token in
/// **0.72 s p50**; the same turn through Hermes answers in **1.15 s** on an
/// idle machine and **1.89 s** under ordinary load. Add the sentence the
/// chunker has to see before it can break (§`Conductor.popSentence`) and the
/// synthesiser's render, and the log says what that adds up to:
///
///     10:54:07  → Busy day
///     10:54:08  turn: first token 1.3 s after the mic closed
///     10:54:12  turn: first word heard 5.2 s after the mic closed
///
/// None of that leg is Moe's to make faster — it is a network round trip and
/// somebody else's model. What *is* Moe's is the silence in front of it. A
/// person asked to do something says "yeah, one sec" before they start; they
/// do not go quiet for two seconds and then begin. So the opener is spoken
/// from here, off the transcript, with no round trip: ~26 ms of streaming
/// synthesis (PocketTTS) or ~180 ms of Kokoro, against 1900 ms of waiting.
///
/// The rule that keeps it honest: **an ack only ever restates the request.**
/// It never predicts an outcome. "Yeah, setting that up" is true the moment
/// the work is handed off, and stays true if the work then fails — which is
/// the difference between this and "done". Nothing here claims a result,
/// names a tool, or says anything the user did not just say themselves.
///
/// A turn it cannot describe from the user's own words returns nil and Moe
/// waits for the model, because a wrong account of what your computer is
/// about to do is worse than a pause.
public enum InstantAck {

    /// What to say now, or nil to stay quiet and let the model speak first.
    ///
    /// - Parameters:
    ///   - request: the user's turn, as transcribed.
    ///   - variant: rotated by the caller so two turns in a row do not get
    ///     the same words. Any value is valid; it is taken modulo the
    ///     number of phrasings.
    public static func phrase(for request: String, variant: Int = 0) -> String? {
        let words = self.words(of: request)
        guard !words.isEmpty else { return nil }

        // Social turns and closings. "Thanks", "cool", "busy day" get an
        // ordinary reply, and an "on it" in front of one would be absurd.
        if isSocial(words) { return nil }

        guard let intent = intent(of: words) else { return nil }
        let options = intent.phrasings
        return options[abs(variant) % options.count]
    }

    // MARK: - Intents

    /// The shape of the request, as far as its own verb admits. Each case
    /// carries only phrasings that stay true whatever the work returns.
    enum Intent {
        /// Bring something into being: a cron, a note, a file, an event.
        case create
        /// Change something that already exists.
        case change
        /// Compose something to go out — but not *send* it. Moe's send gate
        /// may still stop and ask, so nothing here promises delivery.
        case draft
        /// Take something away. Deliberately vaguer than the rest: the gate
        /// often asks first, and "deleting that" would be a lie while a
        /// dialog is up.
        case remove
        /// Go and find out. The commonest voice turn there is.
        case look
        /// Start something running.
        case start
        /// A long job the user has framed as work rather than a question.
        case work

        var phrasings: [String] {
            switch self {
            case .create: return ["Yeah, setting that up.", "On it — making that now.", "Sure, putting that together."]
            case .change: return ["Yeah, changing that.", "On it.", "Sure, updating that now."]
            case .draft:  return ["Yeah, let me get that ready.", "On it — writing that up.", "Sure, drafting that."]
            case .remove: return ["Yeah, let me take care of that.", "On it.", "Sure, dealing with that."]
            case .look:   return ["Yeah, let me look.", "One sec, checking.", "Sure — having a look now."]
            case .start:  return ["Yeah, starting that.", "On it.", "Sure, getting that going."]
            case .work:   return ["Yeah, on it.", "One sec.", "Sure, getting into that."]
            }
        }
    }

    /// Leading verbs, longest phrase first so "set up" beats "set".
    private static let verbs: [(phrase: [String], intent: Intent)] = [
        (["set", "up"], .create), (["put", "together"], .create), (["write", "up"], .create),
        (["make", "me"], .create), (["add"], .create), (["create"], .create),
        (["make"], .create), (["schedule"], .create), (["book"], .create),
        (["remind"], .create), (["build"], .create), (["draft"], .draft),
        (["write"], .create), (["save"], .create), (["note"], .create),
        (["jot"], .create), (["log"], .create), (["set"], .create),

        (["rename"], .change), (["move"], .change), (["change"], .change),
        (["update"], .change), (["edit"], .change), (["fix"], .change),
        (["rewrite"], .change), (["reschedule"], .change), (["push"], .change),

        (["reply"], .draft), (["respond"], .draft), (["send"], .draft),
        (["email"], .draft), (["text"], .draft), (["message"], .draft),
        (["forward"], .draft), (["answer"], .draft),

        (["delete"], .remove), (["remove"], .remove), (["cancel"], .remove),
        (["clear"], .remove), (["unsubscribe"], .remove), (["archive"], .remove),
        (["turn", "off"], .remove), (["get", "rid"], .remove),

        (["look"], .look), (["check"], .look), (["find"], .look),
        (["search"], .look), (["read"], .look), (["show"], .look),
        (["tell", "me"], .look), (["pull", "up"], .look), (["see"], .look),
        (["summarise"], .look), (["summarize"], .look), (["catch", "me"], .look),
        (["what"], .look), (["when"], .look), (["who"], .look), (["where"], .look),
        (["which"], .look), (["any"], .look), (["how", "many"], .look),
        (["how", "much"], .look), (["did"], .look), (["do", "i"], .look),
        (["is", "there"], .look), (["are", "there"], .look), (["anything"], .look),

        (["open"], .start), (["play"], .start), (["launch"], .start),
        (["start"], .start), (["run"], .start), (["call"], .start),
        (["join"], .start), (["record"], .start),

        (["go", "and"], .work), (["work"], .work), (["sort"], .work),
        (["deal"], .work), (["handle"], .work), (["help", "me"], .work),
        (["figure"], .work), (["work", "out"], .work), (["can", "you"], .work),
        (["could", "you"], .work), (["please"], .work), (["i", "need"], .work),
        (["i", "want"], .work),
    ]

    /// Purely social turns, and the ones that close a conversation. A whole
    /// turn made only of these words never gets an ack.
    private static let social: Set<String> = [
        "thanks", "thank", "you", "cheers", "ta", "cool", "nice", "great",
        "lovely", "perfect", "brilliant", "amazing", "awesome", "ok", "okay",
        "kay", "right", "sure", "yeah", "yep", "yes", "no", "nope", "nah",
        "hi", "hello", "hey", "moe", "morning", "good", "afternoon",
        "evening", "night", "bye", "goodbye", "later", "wow", "huh", "hmm",
        "mm", "oh", "ah", "damn", "ouch", "busy", "day", "fine", "alright",
        "stop", "wait", "never", "mind", "forget", "it", "nothing", "sorry",
        "that", "s", "all", "too", "much", "quiet", "shush", "enough",
    ]

    // MARK: - Reading the turn

    private static func words(of request: String) -> [String] {
        request
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// True when nothing in the turn is more than a pleasantry.
    private static func isSocial(_ words: [String]) -> Bool {
        // A long turn is doing something even if it opens politely.
        guard words.count <= 6 else { return false }
        return words.allSatisfy { social.contains($0) }
    }

    /// The intent of the turn, from the first verb phrase that matches in the
    /// opening few words.
    ///
    /// Only the opening is read. A verb deep inside a sentence usually
    /// belongs to something the user is describing rather than asking for
    /// ("the mail from Eli says to delete the branch"), and acking that
    /// would be an account of the wrong thing.
    private static func intent(of words: [String]) -> Intent? {
        let head = Array(words.prefix(4))
        // "Hey Moe" and a name are addressing, not asking; step past them.
        var start = 0
        while start < head.count, ["hey", "hi", "hello", "moe", "ok", "okay", "so", "um", "uh", "and", "also", "please"].contains(head[start]) {
            start += 1
        }
        guard start < head.count else { return nil }

        // Longest match first, and only from the first two words after the
        // address — further in and it is no longer the request's own verb.
        for offset in start..<min(start + 2, head.count) {
            let tail = Array(head[offset...])
            let matches = verbs
                .filter { $0.phrase.count <= tail.count && Array(tail.prefix($0.phrase.count)) == $0.phrase }
                .sorted { $0.phrase.count > $1.phrase.count }
            if let best = matches.first { return best.intent }
        }
        return nil
    }
}
