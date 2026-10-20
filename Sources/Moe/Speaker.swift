import AVFoundation
import Foundation
import MoeChat
import MoeMeeting
import MoeVoice

/// Speaks Moe's reply as it streams in.
///
/// Text arrives token by token, so we buffer until a sentence boundary and hand
/// each finished sentence to AVSpeechSynthesizer. That gets the first words out
/// of the speaker while the rest of the answer is still generating.
@MainActor
final class Speaker: NSObject {

    private let synth = AVSpeechSynthesizer()
    private var buffer = ""
    private var voice: AVSpeechSynthesisVoice?
    private let config: Config

    var onStarted: (() -> Void)?
    var onFinished: (() -> Void)?

    private var pending = 0
    private var streamClosed = false

    /// Bumped by `stop()`. Callbacks from utterances belonging to an older
    /// generation are ignored, which is the only reliable way to keep the
    /// pending count honest: `stopSpeaking(.immediate)` delivers one `didCancel`
    /// per queued utterance, and trusting a counter through that is how the UI
    /// ends up stuck mid-turn.
    private var generation = 0

    init(config: Config) {
        self.config = config
        super.init()
        synth.delegate = self
        voice = Speaker.resolveVoice(named: config.voice, locale: config.locale)
    }

    var isSpeaking: Bool { synth.isSpeaking || pending > 0 }

    /// Feed streaming text; complete sentences are spoken immediately.
    func feed(_ chunk: String) {
        guard config.speakReplies else { return }
        buffer += chunk
        while let sentence = Speaker.popSentence(&buffer) { enqueue(sentence) }
    }

    /// No more text is coming. Returns true if anything is or will be spoken.
    @discardableResult
    func endOfStream() -> Bool {
        guard config.speakReplies else { onFinished?(); return false }
        streamClosed = true
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !rest.isEmpty { enqueue(rest) }
        if pending == 0 {
            streamClosed = false
            onFinished?()
            return false
        }
        return true
    }

    func stop() {
        generation += 1
        buffer = ""
        pending = 0
        streamClosed = false
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    func reset() {
        stop()
    }

    // MARK: - Internals

    private func enqueue(_ text: String) {
        let clean = Speaker.strippedForSpeech(text)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        u.voice = voice
        u.rate = config.speechRate
        u.prefersAssistiveTechnologySettings = false
        if pending == 0 { onStarted?() }
        pending += 1
        utteranceGeneration[ObjectIdentifier(u)] = generation
        synth.speak(u)
    }

    private var utteranceGeneration: [ObjectIdentifier: Int] = [:]

    fileprivate func utteranceEnded(_ u: AVSpeechUtterance) {
        let key = ObjectIdentifier(u)
        let gen = utteranceGeneration.removeValue(forKey: key)
        guard gen == generation else { return }   // stale, from before stop()
        pending = max(0, pending - 1)
        if pending == 0 && streamClosed {
            streamClosed = false
            onFinished?()
        }
    }

    /// Split off the first complete sentence, if there is one.
    private static func popSentence(_ buf: inout String) -> String? {
        let terminators: Set<Character> = [".", "!", "?", "\n"]
        var idx = buf.startIndex
        var found: String.Index?
        while idx < buf.endIndex {
            let c = buf[idx]
            if terminators.contains(c) {
                let next = buf.index(after: idx)
                // Don't split "3.5", or an abbreviation like "Dr." / "Ave."
                if c == ".", next < buf.endIndex, buf[next].isNumber { idx = next; continue }
                if c == ".", isAbbreviation(buf, endingAt: idx) { idx = next; continue }
                if next == buf.endIndex || buf[next].isWhitespace || terminators.contains(buf[next]) {
                    found = next
                    break
                }
            }
            idx = buf.index(after: idx)
        }
        guard let cut = found else {
            // A long run-on with no punctuation: flush at a comma so the first
            // audio doesn't wait for the whole paragraph.
            if buf.count > 140, let comma = buf.firstIndex(of: ",") {
                let s = String(buf[buf.startIndex..<comma])
                buf = String(buf[buf.index(after: comma)...])
                return s.trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        let s = String(buf[buf.startIndex..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        buf = String(buf[cut...])
        return s.isEmpty ? nil : s
    }

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "ave", "rd", "vs", "etc",
        "eg", "ie", "approx", "jr", "sr", "inc", "ltd", "no", "fig",
    ]

    private static func isAbbreviation(_ s: String, endingAt dot: String.Index) -> Bool {
        var start = dot
        var word = ""
        while start > s.startIndex {
            let prev = s.index(before: start)
            let ch = s[prev]
            if ch.isLetter { word.insert(Character(ch.lowercased()), at: word.startIndex) }
            else { break }
            start = prev
            if word.count > 8 { break }
        }
        return abbreviations.contains(word)
    }

    /// Markdown and URLs sound terrible read aloud.
    ///
    /// The rules moved to `MoeVoice.SpokenText`, which this now calls. They
    /// lived here, in an `@MainActor` class inside the executable target, and
    /// so had never had a single test written against them — while being the
    /// one funnel every spoken word in the app passes through
    /// (`VoiceEngine.speak`). Moving them out was what let the gaps be seen:
    /// `www.` addresses, `<https://…>`, numbered lists, table rows, `~~`,
    /// `_emphasis_`, and the colon left dangling in "you can find it at:"
    /// once its address had been taken out.
    ///
    /// What stays here is the one thing that is Moe's rather than markdown's.
    static func strippedForSpeech(_ s: String) -> String {
        // The model's markers are instructions to Moe, not words to say:
        // the end-of-conversation one (Conductor.endMarker) and the two
        // that ask for a meeting (MeetingIntent.Marker).
        let unmarked = MeetingIntent.strippingMarkers(s)
            .replacingOccurrences(of: "<end/>", with: "")
        // A trailing list of sources is for the eyes. Without this the
        // speaker reads "the link, the link, the link" off the end of every
        // piece of web research. It runs before `clean` and not after: it
        // recognises the block by its markdown, which `clean` is about to
        // take away.
        return SpokenText.clean(ReplyLinks.strippingSources(unmarked))
    }

    /// Prefer a premium/enhanced neural voice; fall back to anything sane.
    static func resolveVoice(named name: String, locale: String) -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let lang = locale.replacingOccurrences(of: "_", with: "-")
        if let exact = all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        let localized = all.filter { $0.language.hasPrefix(String(lang.prefix(2))) }
        if let premium = localized.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = localized.first(where: { $0.quality == .enhanced }) { return enhanced }
        return localized.first ?? AVSpeechSynthesisVoice(language: lang)
    }

    static func availableVoiceNames(locale: String) -> [String] {
        let prefix = String(locale.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
            .map { $0.name }
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in utteranceEnded(u) }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in utteranceEnded(u) }
    }
}
