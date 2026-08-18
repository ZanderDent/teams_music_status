import XCTest
@testable import TeamsMusicStatusCore

/// Live measurements against the real Spotify app.
///
/// Skipped unless `TMS_LIVE_SPOTIFY=1`, because they need a running Spotify with playback
/// and the Automation grant — neither of which exists on a CI runner. Run them by hand:
///
///     TMS_LIVE_SPOTIFY=1 swift test --filter SpotifyLocalLiveTests
///
/// These exist because the local source's reliability was, at one point, asserted from a
/// diagnostic that manufactured its own failures. Numbers here come from the production
/// code path, not a re-implementation of it.
final class SpotifyLocalLiveTests: XCTestCase {

    private var live: Bool { ProcessInfo.processInfo.environment["TMS_LIVE_SPOTIFY"] == "1" }

    override func setUpWithError() throws {
        try XCTSkipUnless(live, "set TMS_LIVE_SPOTIFY=1 to run live Spotify measurements")
    }

    /// 300 synchronous reads through the production path. Any throw is a failure; so is
    /// any reading that claims silence while Spotify is playing.
    func testTwoThousandProductionReads() throws {
        var playing = 0, paused = 0, silent = 0
        var failures: [String] = []
        var latencies: [TimeInterval] = []

        for _ in 0..<2000 {
            let started = Date()
            do {
                let reading = try SpotifyLocalSource.readSynchronously()
                latencies.append(Date().timeIntervalSince(started))
                switch reading {
                case .playing: playing += 1
                case .paused: paused += 1
                case .stopped, .notRunning: silent += 1
                }
            } catch {
                failures.append("\(error)")
            }
        }

        let sorted = latencies.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let worst = sorted.last ?? 0
        print("""
          2000 production reads — playing=\(playing) paused=\(paused) silent=\(silent) \
          failures=\(failures.count)
          latency median=\(Int(median * 1000))ms worst=\(Int(worst * 1000))ms
        """)
        if let first = failures.first { print("  first failure: \(first)") }

        XCTAssertTrue(failures.isEmpty, "\(failures.count)/2000 reads failed: \(failures.prefix(3))")
        XCTAssertEqual(silent, 0, "reported silence \(silent) times while Spotify was playing")
    }

    /// The path the app actually uses: async, off the caller's actor.
    func testOneHundredAsyncReads() async throws {
        let source = SpotifyLocalSource()
        var silent = 0
        var failures: [String] = []
        for _ in 0..<100 {
            do {
                let reading = try await source.read()
                if reading.isDefinitelySilent { silent += 1 }
            } catch {
                failures.append("\(error)")
            }
        }
        print("  100 async reads — failures=\(failures.count) silent=\(silent)")
        XCTAssertTrue(failures.isEmpty, "\(failures.count)/100 async reads failed")
        XCTAssertEqual(silent, 0, "reported silence while Spotify was playing")
    }

    /// Rapid polling must not leak threads. A source that accumulates them would take the
    /// whole app down after a few hours of a 3-second poll.
    func testRapidPollingDoesNotLeakThreads() async throws {
        let source = SpotifyLocalSource()
        _ = try? await source.read()
        let before = ProcessInfo.processInfo.activeProcessorCount   // touch, then measure threads
        var threadsBefore = 0
        var count = mach_msg_type_number_t(0)
        var threads: thread_act_array_t?
        if task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS { threadsBefore = Int(count) }

        for _ in 0..<200 { _ = try? await source.read() }

        var threadsAfter = 0
        if task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS { threadsAfter = Int(count) }
        print("  threads before=\(threadsBefore) after=\(threadsAfter) (cores \(before))")
        XCTAssertLessThan(threadsAfter, threadsBefore + 16,
                          "thread count grew from \(threadsBefore) to \(threadsAfter) over 200 reads")
    }
}
