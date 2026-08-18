import Foundation

/// Runs AppleScript on one dedicated thread that owns a live run loop.
///
/// ## Why this exists
///
/// `NSAppleScript` sends an Apple Event and waits for the reply. That reply is delivered
/// through a **run loop**, and a `DispatchQueue` worker thread does not have one running.
/// Most of the time the event completes anyway; occasionally it does not, and the call
/// blocks until something gives up.
///
/// Measured, with Spotify playing normally:
///
///   * on the main thread, 20 cold processes: 20/20 in ~200ms, execute ~150ms
///   * on a global queue with the caller blocked, cold processes: roughly 1 in 12 never
///     returned, hitting a 20-second deadline exactly
///
/// The Apple Event itself was never slow. The reply had nowhere to land.
///
/// ## What this gives us
///
/// * **A run loop for replies.** The thread runs one for its whole life.
/// * **Serialisation, for free.** One thread means one script at a time, so a poll can
///   never start a second read while the first is unresolved — no pile-up of stuck
///   Apple Event threads, which is the failure mode that would actually take the app down.
/// * **The main actor stays free.** The UI never waits on Spotify.
///
/// A wedged event still blocks *this* thread, and there is no way to cancel an in-flight
/// Apple Event. That is bounded to exactly one thread and one queued backlog, and callers
/// time out independently, so a stuck read degrades to "no reading this tick" rather than
/// to a hung app.
final class SpotifyScriptRunner: @unchecked Sendable {

    static let shared = SpotifyScriptRunner()

    private let thread: Thread
    private let ready = DispatchSemaphore(value: 0)

    private init() {
        var startedThread: Thread!
        let readySignal = ready
        startedThread = Thread {
            // A port keeps the run loop alive with no input sources of its own; without
            // one, `run()` returns immediately and the thread exits.
            let runLoop = RunLoop.current
            runLoop.add(NSMachPort(), forMode: .default)
            readySignal.signal()
            while !Thread.current.isCancelled {
                runLoop.run(mode: .default, before: .distantFuture)
            }
        }
        startedThread.name = "com.zanderdent.TeamsMusicStatus.applescript"
        // Above default so a status read is not starved by background work, below the UI.
        startedThread.qualityOfService = .utility
        thread = startedThread
        thread.start()
        // Wait for the run loop to exist before anything is scheduled onto it.
        _ = ready.wait(timeout: .now() + 5)
    }

    /// Run `work` on the script thread and wait for it.
    ///
    /// The caller is always a background queue, never the main actor, so this blocks only
    /// a worker. Returns nil if the thread did not produce a result within `timeout`; the
    /// work itself is left to finish, because an in-flight Apple Event cannot be cancelled.
    func run<T>(timeout: TimeInterval, _ work: @escaping () -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let block = BlockWrapper {
            box.value = work()
            done.signal()
        }
        block.perform(#selector(BlockWrapper.invoke), on: thread, with: nil, waitUntilDone: false,
                      modes: [RunLoop.Mode.default.rawValue])
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// `perform(_:on:with:)` needs an ObjC selector, so the closure is carried by an object.
private final class BlockWrapper: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}
