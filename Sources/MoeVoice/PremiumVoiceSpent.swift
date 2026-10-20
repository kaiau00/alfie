import Foundation

/// The premium voice's account has run out of credits.
///
/// Inworld answers a render on an account with nothing left with an error
/// event — "You have no credits remaining. Please add credits to continue
/// using the service." (HTTP 402 on its REST face) — and the socket, the
/// credential and the next render are all otherwise fine. So each batch of a
/// reply was minted a fresh credential (0.6–2.6 s), refused, and re-rendered
/// on the local engine: on the owner's Mac on 2026-09-24 from 14:28 to 14:32
/// every batch of every reply went that way, in the local voice rather than
/// the chosen one, and nothing ever said why (ticket #12).
///
/// A refusal like that does not heal between two sentences. `SpeechOut`
/// stops asking for the rest of the voice's life, speaks locally at the next
/// sentence, and says so once in the conversation.
public enum PremiumVoiceSpent {

    /// Whether this failure is the account being out of credits — not a
    /// dropped socket or a malformed request, which are worth trying again.
    public static func matches(_ error: Error) -> Bool {
        guard case InworldError.rejected(let message) = error else { return false }
        let m = message.lowercased()
        return m.contains("credit") || m.contains("payment required") || m.contains("402")
            || m.contains("quota") || m.contains("insufficient balance")
    }

    /// What the person is told, once. Plain words: which voice, why, and
    /// that Moe carries on.
    public static let notice =
        "The premium voice has run out of credits, so Moe is using its built-in voice for now."
}
