import Foundation

/// Builds the brain. The only place in the app that names a concrete adapter.
///
/// There is one: Hermes Agent, which Moe runs as a supervised child. The
/// `claude -p` and `gemini` adapters that used to live beside it moved into
/// Hermes (HERMES-PLAN.md, "What gets deleted") — Claude Code is now the
/// gateway's own child, signed in with a setup-token by
/// `scripts/hermes-signin.sh`.
enum BrainFactory {
    static func make(config: Config) -> BrainProvider {
        switch config.brain {
        case .hermes:
            // Moe runs the gateway itself; the brain waits for it to answer.
            return HermesBrain(config: config, supervisor: HermesSupervisor(config: config))
        }
    }
}
