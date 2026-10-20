import Foundation

/// Reading a local model server's catalogue, and choosing from it.
///
/// The two pure decisions inside `LocalModelServer` (app target, which does
/// the networking), split out for the reason `CursorPrefix`, `WordErrorRate`
/// and `PolishTier` were: they have edge cases worth pinning, and a test that
/// needs a running Ollama to catch a parsing bug will not be run.
public enum LocalModelChoice {

    /// Model ids from an OpenAI-shaped `/v1/models` body, which both Ollama
    /// and LM Studio serve. An empty array is a real answer — a server can be
    /// running with nothing pulled, and that looks identical from outside
    /// until it is asked to generate.
    public static func modelIDs(from data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    /// Which model to use for a dictation rewrite: the smallest.
    ///
    /// A rewrite is mechanical — a 3B does it as well as a 70B and several
    /// times faster, which is the entire reason this tier exists. Picking the
    /// first or the most capable would give away the speed we came for.
    ///
    /// Sizes are read from the name, which is the only place they appear:
    /// "llama3.2:3b", "qwen2.5-7b-instruct", "phi4-mini-3.8B". A name with no
    /// size still counts, but loses to any name that has one — otherwise a
    /// list whose first entry happened to be a 70B would win on position.
    public static func preferredModel(from models: [String]) -> String? {
        let sized = models.compactMap { m in billions(in: m).map { (m, $0) } }
        if let smallest = sized.min(by: { $0.1 < $1.1 }) { return smallest.0 }
        return models.first
    }

    /// The parameter count a model name claims, in billions.
    ///
    /// Only a number immediately followed by "b" counts, so the "3.2" in
    /// "llama3.2:1b" is read as a version and ignored — otherwise a 1B model
    /// would be ranked as 3.2B and lose to genuinely larger ones. The upper
    /// bound rejects a stray year or hash that happens to end in b.
    static func billions(in id: String) -> Double? {
        var best: Double?
        var number = ""
        for ch in id.lowercased() {
            if ch.isNumber || ch == "." {
                number.append(ch)
            } else {
                if ch == "b", let v = Double(number), v > 0, v < 500 {
                    best = min(best ?? v, v)
                }
                number = ""
            }
        }
        return best
    }
}
