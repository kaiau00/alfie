import Foundation
import MoeDictation

/// Who rewrites a dictation, and the rule for choosing.
///
/// Same shape as `SttBackend` and `TtsBackend`: implementations take text and
/// return text, never touch the audio graph or the pasteboard, and load
/// lazily so a backend this Mac cannot use is never paid for. The user
/// chooses an *outcome* — fast, private, or "use my AI" — never an engine.
///
/// **Why this exists.** The rewrite was one hard-wired call to the
/// conversation's brain, and on a Claude subscription that means Hermes
/// spawning a `claude` child: an agent runtime, with its own thinking, asked
/// to fix punctuation on thirty words. Measured over 29 real dictations:
/// speech engines 307 ms, rewrite 3604 ms — 92% of the wait, with excursions
/// past the budget that drop the rewrite entirely. The model was never the
/// cost; the transport was.
///
/// Both mature open-source dictation tools reached the same answer
/// independently, and neither uses a cloud API for it:
///
/// - **OpenWhispr** runs a local GGUF model through llama.cpp
///   (`localReasoningBridge.js`), with thinking disabled by default and
///   `stripThinkingTags` on the output.
/// - **Handy** calls Apple's on-device model on macOS, via Swift and C FFI
///   from Rust (`apple_intelligence.rs`).
///
/// A dictation polish is a small, local, thinking-off job. That is the whole
/// insight, and it is also what makes PRODUCT.md §4.1's promise true — "the
/// dictation is free forever, because it runs on your Mac and costs us
/// nothing" is not true of a cloud round trip.
///
/// **Portability.** The ordering below is deliberately not Apple-shaped.
/// `.appleOnDevice` is one implementation behind an availability check; the
/// tier that carries Windows and Linux is `.localServer`, which is Hermes
/// talking to Ollama or LM Studio and already exists in `BrainProviderKind`
/// (`lmstudio`, `custom`). When the Tauri shell lands (CROSS-PLATFORM.md),
/// the protocol and every tier below Apple port unchanged.
protocol PolishBackend: Sendable {
    /// Neutral name for the UI — what it is good at, never what it is.
    var displayName: String { get }
    /// Whether this backend can run at all right now. Cheap and synchronous
    /// where possible: it is consulted to pick a tier, not to do work.
    var isAvailable: Bool { get async }
    /// True when nothing leaves this machine. Drives the Settings copy, which
    /// must never overstate privacy.
    var isOnDevice: Bool { get }
    /// Warm whatever needs warming. Never required; `polish` works cold.
    func warmUp() async
    /// The rewritten text, or nil to keep what the caller already has.
    /// Implementations must return nil rather than throw on any failure:
    /// dictation is never blocked on a rewrite.
    func polish(_ text: String, prompt: PolishPrompt.Assembled,
                budget: TimeInterval) async -> String?
}
