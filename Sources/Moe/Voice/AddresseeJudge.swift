import Foundation
import MoeVoice
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The one-token classifier for the follow-up window. VOICE-PLAN.md §4.3.
///
/// Only when the cheap signals disagree (`Addressee.verdict == .unsure`),
/// Apple's on-device model is shown the exchange — Moe's last reply and
/// the new words — and asked for one word. About 300 ms on an M-series
/// Mac; needs Apple Intelligence on, and without it the rules alone
/// decide (unsure means discard). Nothing leaves the Mac.
actor AddresseeJudge {

    static let budget: TimeInterval = 0.9

    #if canImport(FoundationModels)
    /// Held as `Any?` and cast on the way out, because Swift refuses a
    /// STORED property marked `@available` — "stored properties cannot be
    /// marked potentially unavailable". That single rule, in this one
    /// declaration and one more in AppleOnDevicePolish, is what forced the
    /// whole app's deployment target to macOS 26 and told every Mac on 15
    /// that it could not run Moe. Every call site below was already behind
    /// `if #available`; only the TYPE here could not be deferred.
    ///
    /// The box holds a `LanguageModelSession` when there is one, and nothing
    /// at all on an older macOS — where `isAvailable` is false and no path
    /// reaches the accessor.
    private var sessionBox: Any?
    @available(macOS 26.0, *)
    private var session: LanguageModelSession? {
        get { sessionBox as? LanguageModelSession }
        set { sessionBox = newValue }
    }
    #endif

    private static let instructions = """
    A person is talking near an assistant named Alfie, a moment after Alfie \
    finished answering them. Decide what the sentence is. Answer with \
    exactly one word:

    DIRECTED - it is for Alfie: a follow-up question, a request, or an answer \
    to what Alfie just asked.
    NOT - it is for another person, or the person talking to themselves, or \
    dictating something to a different device.
    DONE - it is for Alfie and it means the conversation is over: they are \
    thanking Alfie off, saying they were not talking to it, telling it to \
    stop, or saying goodbye.
    UNSURE - it could be any of these.

    The sentence may be in any language. Answer with the English word only.
    """

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    func warmUp() {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return }
        let s = LanguageModelSession(instructions: Self.instructions)
        s.prewarm()
        session = s
        #endif
    }

    /// Whichever of the model and the deadline arrives first; the other
    /// is dropped.
    private final class Resumer: @unchecked Sendable {
        private var cont: CheckedContinuation<String?, Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<String?, Never>) { cont = c }
        func finish(_ value: String?) {
            lock.lock()
            let c = cont
            cont = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// Nil when unavailable, over budget, or the answer is not one of the
    /// three words — the rules' verdict then stands.
    func judge(moeSaid: String, heard: String) async -> Addressee.Verdict? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return nil }
        if session == nil { warmUp() }
        guard let session else { return nil }
        let prompt = "Alfie said: “\(String(moeSaid.suffix(400)))”\nThen the person said: “\(String(heard.prefix(300)))”\nOne word:"
        let began = Date()
        // The session is not reused: its transcript grows by every
        // exchange and the context window ends the feature silently
        // after a couple of dozen turns. A prewarmed spare is kept for
        // the next call instead.
        self.session = nil
        let work = Task { () -> String? in
            do { return try await session.respond(to: prompt).content }
            catch { Log.write("addressee: judge failed (\(error))"); return nil }
        }
        // The deadline is the caller's, whatever the model does: an
        // answer that arrives late is thrown away, not waited for.
        let answer: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                let box = Resumer(cont)
                Task { let value = await work.value; box.finish(value) }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(Self.budget * 1_000_000_000))
                    box.finish(nil)
                }
            }
        } onCancel: { work.cancel() }
        warmUp()
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        guard let answer else { Log.write("addressee: judge over budget (\(ms) ms)"); return nil }
        let word = answer.uppercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // The words are the room's, not Moe's: only the verdict is logged.
        let verdict: Addressee.Verdict?
        if word.hasPrefix("DIRECTED") { verdict = .directed }
        else if word.hasPrefix("DONE") { verdict = .done }
        else if word.hasPrefix("NOT") { verdict = .notDirected }
        else if word.hasPrefix("UNSURE") { verdict = .unsure }
        else { verdict = nil }
        Log.write("addressee: judge said \(verdict.map { "\($0)" } ?? "nothing usable") in \(ms) ms")
        return verdict
        #else
        return nil
        #endif
    }
}
