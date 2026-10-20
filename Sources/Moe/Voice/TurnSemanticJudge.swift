import Foundation
import MoeVoice
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, asked one thing at a pause: has the person
/// finished, or will they go on? One word back (`TurnSemantics`).
///
/// Asked only where the rules have no opinion (`TurnSemantics.read` is
/// `.unknown`), beside Smart Turn, and waited for no longer than `budget`:
/// a late answer is thrown away, and a Mac without Apple Intelligence — or
/// with the model still downloading — answers nothing at once. Either way
/// the rules and the audio decide, exactly as they did before this existed
/// (fail open). Nothing leaves the Mac; the words are never logged.
///
/// Built like `AddresseeJudge`: a fresh session per question (a reused one
/// grows its transcript until the context window ends the feature), with a
/// prewarmed spare kept for the next.
actor TurnSemanticJudge {

    /// The longest a verdict waits for the model. Measured on this Mac by
    /// `Moe --turn-semantics` (turn-semantics.md); the bench scores the
    /// policy with the model's measured latencies against this same budget.
    static let budget: TimeInterval = 0.3

    #if canImport(FoundationModels)
    /// `Any?` for the reason `AddresseeJudge` gives: a stored property may not
    /// be `@available`, and this one must not raise the deployment target.
    private var sessionBox: Any?
    @available(macOS 26.0, *)
    private var session: LanguageModelSession? {
        get { sessionBox as? LanguageModelSession }
        set { sessionBox = newValue }
    }
    #endif

    static let instructions = """
    You listen to a person talking to a voice assistant. They have just \
    paused. You see the words they have said so far, from a speech \
    recogniser: no punctuation, sometimes misheard. Decide whether they have \
    finished what they wanted to say, or will go on after the pause. Answer \
    with exactly one word:

    DONE - a complete request, question or answer the assistant could act on now.
    MORE - cut off, an unfinished thought, or plainly leading into more.
    """

    static func prompt(_ text: String) -> String {
        "Words so far: “\(String(text.suffix(300)))”\nOne word:"
    }

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

    private final class Resumer: @unchecked Sendable {
        private var cont: CheckedContinuation<String?, Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<String?, Never>) { cont = c }
        func finish(_ value: String?) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(returning: value)
        }
    }

    /// The model's reading of `text`, and how long it took. Nil reading when
    /// unavailable, over `budget`, or not one of the two words.
    func judge(_ text: String, budget: TimeInterval = budget) async -> (reading: TurnSemantics.Reading?, ms: Int) {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else { return (nil, 0) }
        if session == nil { warmUp() }
        guard let session else { return (nil, 0) }
        self.session = nil
        let prompt = Self.prompt(text)
        let began = Date()
        let work = Task { () -> String? in
            do {
                let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 3)
                return try await session.respond(to: prompt, options: options).content
            } catch { return nil }
        }
        let answer: String? = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
                let box = Resumer(cont)
                Task { let value = await work.value; box.finish(value) }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                    box.finish(nil)
                }
            }
        } onCancel: { work.cancel() }
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        warmUp()
        return (answer.flatMap(TurnSemantics.parseModelAnswer), ms)
        #else
        return (nil, 0)
        #endif
    }

    /// `Moe --turn-semantics <texts.txt> <out.json> [--budget ms] [--gap ms]`:
    /// every line asked once, as the engine asks (fresh prewarmed session,
    /// `gap` of quiet between questions so the spare is warm, as it is
    /// between real pauses), with no deadline so the true latency is
    /// recorded; the replay applies the budget. Prints the latency
    /// distribution and writes `{key: {reading, ms}}` for `--model-table`.
    static func measure(_ args: [String]) async -> Int32 {
        guard args.count >= 2, let input = try? String(contentsOfFile: args[0], encoding: .utf8) else {
            print("usage: Moe --turn-semantics <texts.txt> <out.json> [--gap ms] [--limit n]")
            return 2
        }
        func value(_ flag: String) -> Double? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return Double(args[i + 1])
        }
        let gap = (value("--gap") ?? 300) / 1000
        var texts = input.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if let n = value("--limit") { texts = Array(texts.prefix(Int(n))) }
        let judge = TurnSemanticJudge()
        guard await judge.isAvailable else {
            print("on-device model: NOT available — nothing measured (the policy then runs on the rules alone)")
            return 1
        }
        await judge.warmUp()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var table: [String: PolicyReplay.ModelAnswer] = [:]
        var times: [Double] = []
        var counts: [String: Int] = [:]
        let began = Date()
        for (i, text) in texts.enumerated() {
            let (reading, ms) = await judge.judge(text, budget: 10)
            table[TurnSemantics.key(text)] = PolicyReplay.ModelAnswer(reading: reading, ms: Double(ms))
            times.append(Double(ms))
            counts[reading?.rawValue ?? "none", default: 0] += 1
            if (i + 1) % 100 == 0 {
                print("  \(i + 1)/\(texts.count) in \(Int(Date().timeIntervalSince(began))) s")
            }
            try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
        }
        let sorted = times.sorted()
        func q(_ f: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * f))] }
        print(String(format: "%d texts: p50 %.0f ms, p90 %.0f ms, p99 %.0f ms, max %.0f ms; under 300 ms: %.1f%%",
                     sorted.count, q(0.5), q(0.9), q(0.99), sorted.last ?? 0,
                     100 * Double(sorted.filter { $0 <= 300 }.count) / Double(max(1, sorted.count))))
        print("readings: " + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        do {
            let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
            try enc.encode(table).write(to: URL(fileURLWithPath: args[1]))
        } catch { print("could not write \(args[1]): \(error)"); return 1 }
        print("→ \(args[1])")
        return 0
    }
}
