import XCTest
@testable import TeamsMusicStatusCore

/// The general invariant, not the symptoms.
///
/// If Teams is running, there is something to sync, nobody is in a call, and a status
/// operation has been failing for a sustained period despite ordinary repair, the app must
/// escalate to a bounded restart rather than retrying the same failing operation forever.
///
/// Written from the failure that motivated it: the profile control refused AXPress, Return
/// and Space for four minutes while `health()` reported `healthy` throughout, so neither
/// the `treeUnavailable` nor the `noWindow` escalation applied and nothing ever escalated.
final class SustainedFailureRecoveryTests: XCTestCase {

    private let policy = TeamsRestartRecovery.Policy()

    private func decide(failures: Int,
                        elapsed: TimeInterval? = nil,
                        somethingToSync: Bool = true,
                        audio: Bool = false,
                        restarts: Int = 0,
                        sinceRestart: TimeInterval? = nil,
                        recovering: Bool = false) -> TeamsRestartRecovery.Decision {
        TeamsRestartRecovery.decideSustainedFailureRestart(
            consecutiveOperationFailures: failures,
            secondsSinceFirstFailure: elapsed ?? policy.sustainedFailureInterval + 1,
            hasSomethingToSync: somethingToSync,
            audioCaptureActive: audio,
            restartsSoFar: restarts,
            secondsSinceLastRestart: sinceRestart,
            recoveryInProgress: recovering,
            policy: policy)
    }

    // MARK: A single failure is not a broken Teams

    /// The most important negative. AX operations fail transiently all the time; treating
    /// one as evidence would restart Teams during ordinary use.
    func testOneTransientControlFailureDoesNotRestartTeams() {
        XCTAssertFalse(decide(failures: 1).isGo)
        XCTAssertFalse(decide(failures: 2).isGo)
        XCTAssertFalse(decide(failures: policy.operationFailuresBeforeRestart - 1).isGo)
    }

    /// A burst is not a sustained failure either. Four failures in five seconds is one bad
    /// moment; the same four across two minutes is a Teams that is not working.
    func testABurstOfFailuresIsNotEnoughWithoutDuration() {
        XCTAssertFalse(decide(failures: 99, elapsed: 5).isGo)
        XCTAssertFalse(decide(failures: 99, elapsed: policy.sustainedFailureInterval - 1).isGo)
    }

    func testEscalatesOnceFailuresAreBothRepeatedAndSustained() {
        XCTAssertTrue(decide(failures: policy.operationFailuresBeforeRestart).isGo)
    }

    // MARK: Only when there is work to do

    /// Teams being unusable does not matter while nothing is playing, and restarting an
    /// application the user is not blocked on is pure disruption.
    func testDoesNotRestartWhenThereIsNothingToSync() {
        XCTAssertFalse(decide(failures: 99, somethingToSync: false).isGo)
    }

    // MARK: Call safety, unchanged

    func testDefersWhileAudioIsCaptured() {
        XCTAssertFalse(decide(failures: 99, audio: true).isGo)
        guard case .wait(let reason) = decide(failures: 99, audio: true) else {
            return XCTFail("should wait")
        }
        XCTAssertTrue(reason.contains("call"), reason)
    }

    /// Deferring must not consume the budget, and recovery must resume when the call ends.
    func testDeferredRecoveryProceedsAfterTheCallEnds() {
        for _ in 0..<20 { XCTAssertFalse(decide(failures: 99, audio: true).isGo) }
        XCTAssertTrue(decide(failures: 99, audio: false).isGo)
    }

    // MARK: Never compete with, or duplicate, another recovery

    func testDoesNotEscalateWhileAnotherRecoveryIsRunning() {
        XCTAssertFalse(decide(failures: 99, recovering: true).isGo)
    }

    // MARK: Bounded

    func testRespectsTheRestartCooldownAndCap() {
        XCTAssertFalse(decide(failures: 99, restarts: 1, sinceRestart: 30).isGo)
        XCTAssertTrue(decide(failures: 99, restarts: 1, sinceRestart: policy.cooldown + 1).isGo)
        XCTAssertFalse(decide(failures: 99, restarts: policy.maxRestarts, sinceRestart: 9999).isGo)
    }

    /// The loop this whole layer exists to prevent: repeated failure must terminate.
    func testSustainedFailureCannotLoop() {
        var restarts = 0
        for _ in 0..<50 where decide(failures: 99, restarts: restarts, sinceRestart: 9999).isGo {
            restarts += 1
        }
        XCTAssertEqual(restarts, policy.maxRestarts)
    }

    /// Every held decision must name its guard — these strings drive the user-facing state.
    func testEachGuardExplainsItself() {
        for (decision, expected) in [
            (decide(failures: 1), "enough"),
            (decide(failures: 99, elapsed: 1), "persisted"),
            (decide(failures: 99, somethingToSync: false), "nothing to sync"),
            (decide(failures: 99, audio: true), "call"),
            (decide(failures: 99, recovering: true), "already in progress"),
            (decide(failures: 99, restarts: 99, sinceRestart: 9999), "cap"),
        ] {
            guard case .wait(let reason) = decision else { return XCTFail("should wait") }
            XCTAssertTrue(reason.contains(expected), "expected '\(expected)' in: \(reason)")
        }
    }

    // MARK: Restart outcomes

    /// `open` returning success is not a relaunch. Only `.relaunched` may be treated as
    /// Teams having come back — the distinction the previous actuator did not make, which
    /// left the machine with no Teams at all.
    func testOnlyRelaunchedCountsAsSuccess() {
        XCTAssertTrue(TeamsRestartRecovery.RestartOutcome.relaunched.isRelaunched)
        for outcome: TeamsRestartRecovery.RestartOutcome in [.notRunning, .quitFailed, .relaunchFailed] {
            XCTAssertFalse(outcome.isRelaunched, "\(outcome) must not be treated as recovered")
        }
    }

    /// A Teams that cannot be brought back must end in an actionable state, not another
    /// attempt.
    func testPermanentRelaunchFailureIsDistinguishable() {
        XCTAssertNotEqual(TeamsRestartRecovery.RestartOutcome.relaunchFailed, .notRunning)
        XCTAssertNotEqual(TeamsRestartRecovery.RestartOutcome.relaunchFailed, .relaunched)
    }

    /// A user-quit Teams is `.notRunning`, which is explicitly not a failure to recover
    /// from — this is what stops the app resurrecting a deliberately closed Teams.
    func testUserQuitIsNotAFailureToRecoverFrom() {
        let outcome = TeamsRestartRecovery.RestartOutcome.notRunning
        XCTAssertFalse(outcome.isRelaunched)
        XCTAssertNotEqual(outcome, .relaunchFailed)
    }
}

/// Regressions from the live soak on 2026-08-20, where the layered escalation cycled
/// instead of escalating. Both defects were invisible to unit tests and to manual actuator
/// calls; only watching the coordinator run unaided exposed them.
final class LayeredEscalationRegressionTests: XCTestCase {

    private let policy = TeamsRestartRecovery.Policy()

    /// A cheap recovery reporting success must not, by itself, clear the generic streak.
    ///
    /// Activation produced a window, `health()` stopped reporting `noWindow`, the streak
    /// reset, the window vanished, and the cycle began again — 1/2, 2/2, activate, reset,
    /// forever. Only a completed status operation may count as recovery, so the generic
    /// counter has to survive an apparently-successful repair.
    func testGenericStreakSurvivesAnApparentlySuccessfulRepair() {
        // Four sustained failures reached while a cheap repair keeps "succeeding".
        let decision = TeamsRestartRecovery.decideSustainedFailureRestart(
            consecutiveOperationFailures: policy.operationFailuresBeforeRestart,
            secondsSinceFirstFailure: policy.sustainedFailureInterval + 1,
            hasSomethingToSync: true,
            audioCaptureActive: false,
            restartsSoFar: 0,
            secondsSinceLastRestart: nil,
            recoveryInProgress: false,
            policy: policy)
        XCTAssertTrue(decision.isGo,
                      "a repair that never yields a working status operation must still escalate")
    }

    /// The backstop must be reachable from every symptom, not only from the ones with no
    /// specialised handler. A `noWindow` that recurs indefinitely has to end in a restart.
    func testEverySymptomCanReachTheBackstop() {
        for failures in [policy.operationFailuresBeforeRestart,
                         policy.operationFailuresBeforeRestart + 5] {
            let decision = TeamsRestartRecovery.decideSustainedFailureRestart(
                consecutiveOperationFailures: failures,
                secondsSinceFirstFailure: policy.sustainedFailureInterval + 1,
                hasSomethingToSync: true,
                audioCaptureActive: false,
                restartsSoFar: 0,
                secondsSinceLastRestart: nil,
                policy: policy)
            XCTAssertTrue(decision.isGo)
        }
    }

    /// And the cheap path must still be preferred while it is plausibly working — the
    /// backstop is beneath it, not instead of it.
    func testTheCheapPathIsStillTriedFirst() {
        XCTAssertLessThan(policy.failuresBeforeActivation, policy.operationFailuresBeforeRestart,
                          "activation must be reachable before the restart backstop")
    }
}
