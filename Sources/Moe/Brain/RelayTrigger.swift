import Foundation

/// **The Mac half of CLOUD-PLAN 4a.2**: making an Away enrolment reach the
/// relay now, rather than one launch later.
///
/// The problem it exists for, stated once. This Mac's gateway dials the edge
/// using three settings in `~/.hermes/.env`, written by `configure-hermes.py`
/// from the credential under `~/.moe/cloud/` and `Config.cloudEdge`. But the
/// gateway loads that file into its environment **once, at boot**, and the
/// fork's `register_relay_adapter()` runs **once, at startup** — so a dial
/// written while the gateway is up reaches nothing at all. And the gateway is
/// always up when somebody enrols, because enrolling happens in Settings ›
/// Away, in a running app. Before this, the sequence was: enrol, nothing,
/// quit, reopen, dial.
///
/// So two steps, and both are needed: rewrite the file, then restart the
/// gateway that reads it. Which is why this is not simply a call to
/// `configure-hermes.py` at the enrolment site.
///
/// Lifted out of `Conductor` so that `scripts/test-hermes-supervisor.sh` can
/// drive it against a real supervisor and a real (fake) gateway. A decision
/// that only exists inside a private method of the app's largest type is one
/// that gets tested by reading.
enum RelayTrigger {

    /// Something the dial is derived from moved — this Mac's credential, or
    /// the edge address. `reload` is called on the main queue, and only when
    /// the script reports that the three settings actually changed.
    ///
    /// **The condition is the point.** Rewriting `.env` is cheap and happens
    /// on every launch anyway; respawning the gateway costs the brain child
    /// five to seven seconds of visible stall. Restarting whenever this is
    /// *called*, rather than when something *changed*, would make retyping the
    /// same edge address — or any future caller that fires on a timer — a
    /// stall the person can feel and cannot explain.
    /// One at a time, and never two `configure-hermes.py` processes over one
    /// `.env`.
    ///
    /// **Settings › Away's "Create my tenant" fires this twice**: `saveEdge()`
    /// runs it for the address, and `createTenant` runs it again when the
    /// credential lands, on one click. `atomic_write` makes each write whole
    /// and gives each process its own temp path, so neither can tear the file
    /// — but each is a whole-file replace of a snapshot read seconds earlier,
    /// across a `validate_with_hermes` subprocess, so the loser silently
    /// reverts the winner's relay keys. The gateway then restarts onto the
    /// stale file and dials nothing, having been told the dial changed.
    ///
    /// Serialised rather than locked, because the fix has to hold for the
    /// *other* writer too: `configure-hermes.py` has no `flock` anywhere, and
    /// adding one on the Mac would not stop `enrol` and `forget` racing here.
    private static let queue = DispatchQueue(label: "moe.relay.trigger")
    /// A change that arrived while a run was in flight. Coalesced, not queued:
    /// the script reads the world fresh each time, so two pending reasons and
    /// one pending reason need exactly the same single re-run.
    private static var pending: String?
    private static var running = false

    /// `done` fires on the main queue once the run this call caused — or was
    /// coalesced into — has finished, changed or not. CLOUD-PLAN §19.11: the
    /// Connections screen signs a person in, stores their Composio key, and
    /// then has to wait for `.env` to carry it before the connect script can
    /// reach Composio at all; without this it would race the run.
    static func dialMayHaveMoved(_ why: String,
                                 reload: @escaping (String) -> Void,
                                 done: (() -> Void)? = nil) {
        guard HermesConfigure.wanted else { done.map { DispatchQueue.main.async(execute: $0) }; return }
        queue.async {
            if let done { waiters.append(done) }
            guard !running else {
                // Keep the first reason: it is the one the log will be read
                // back from, and the later one is usually the same click.
                pending = pending ?? why
                Log.write("relay: \(why) — a configure run is already in flight; "
                          + "it will be re-run once")
                return
            }
            running = true
            runLocked(why, reload: reload)
        }
    }

    /// Everyone waiting for the current run (and its coalesced re-run) to end.
    private static var waiters: [() -> Void] = []

    /// Always on `queue`. The 60 s-bounded script runs here rather than on a
    /// global queue so "one at a time" is a property of the queue and not of a
    /// flag somebody has to remember to clear.
    private static func runLocked(_ why: String,
                                  reload: @escaping (String) -> Void) {
        Log.write("relay: \(why) — re-running configure-hermes")
        let changed = HermesConfigure.runAndLog()
        if changed {
            DispatchQueue.main.async { reload("the relay dial changed") }
        } else {
            Log.write("relay: the dial did not change; the gateway is left alone")
        }
        if let next = pending {
            pending = nil
            runLocked(next, reload: reload)
            return
        }
        running = false
        let finished = waiters
        waiters = []
        for w in finished { DispatchQueue.main.async(execute: w) }
    }
}
