import XCTest
@testable import TeamsMusicStatusCore

/// The escalation that restarts Teams. Every guard here exists because the alternative is
/// quitting somebody's Teams at the wrong moment, which is worse than a stale status.
final class TeamsRestartRecoveryTests: XCTestCase {

    private let policy = TeamsRestartRecovery.Policy()

    private func decide(failures: Int,
                        restarts: Int = 0,
                        since: TimeInterval? = nil,
                        audio: Bool = false) -> TeamsRestartRecovery.Decision {
        TeamsRestartRecovery.decide(consecutiveTreeFailures: failures,
                                    restartsSoFar: restarts,
                                    secondsSinceLastRestart: since,
                                    audioCaptureActive: audio,
                                    policy: policy)
    }

    // MARK: In-place recovery comes first

    /// A single failure is ordinary. `ensureHealthy` fixes most of these itself, and a
    /// restart on the first one would fire during every transient hiccup.
    func testOneFailureIsNotEnough() {
        XCTAssertFalse(decide(failures: 1).isGo)
        XCTAssertFalse(decide(failures: 2).isGo)
    }

    /// Each failure is already ~90s of ensureHealthy trying everything else, so the
    /// threshold is roughly five minutes of hard failure before anything disruptive.
    func testRestartsOnceInPlaceRecoveryIsExhausted() {
        XCTAssertTrue(decide(failures: 3).isGo)
        XCTAssertTrue(decide(failures: 9).isGo)
    }

    // MARK: Never interrupt a call

    /// The guard this whole design exists for. A stale status costs nothing; dropping
    /// somebody out of a meeting is the failure mode the project refuses to have.
    func testNeverRestartsWhileAudioIsBeingCaptured() {
        XCTAssertFalse(decide(failures: 99, audio: true).isGo)
    }

    /// Audio is checked before the cap and the cooldown so the log says "not interrupting
    /// a call" rather than "giving up", which would be both wrong and alarming.
    func testAudioIsReportedAheadOfTheOtherGuards() {
        let decision = decide(failures: 99, restarts: 99, since: 0, audio: true)
        guard case .wait(let reason) = decision else { return XCTFail("should wait") }
        XCTAssertTrue(reason.contains("call"), "expected the call guard, got: \(reason)")
    }

    /// And it must resume the moment the call ends — the guard delays recovery, never
    /// cancels it.
    func testRecoveryResumesWhenTheCallEnds() {
        XCTAssertFalse(decide(failures: 5, audio: true).isGo)
        XCTAssertTrue(decide(failures: 5, audio: false).isGo)
    }

    // MARK: Never loop

    /// A Teams that comes back broken must not be restarted again immediately, or the app
    /// becomes the outage.
    func testCooldownBlocksASecondRestart() {
        XCTAssertFalse(decide(failures: 5, restarts: 1, since: 60).isGo)
        XCTAssertFalse(decide(failures: 5, restarts: 1, since: policy.cooldown - 1).isGo)
    }

    func testRestartAllowedOnceTheCooldownHasPassed() {
        XCTAssertTrue(decide(failures: 5, restarts: 1, since: policy.cooldown + 1).isGo)
    }

    /// If a restart cannot fix it, stop. Three failed restarts is evidence the problem is
    /// something else, and killing Teams a fourth time helps nobody.
    func testGivesUpAtTheCap() {
        XCTAssertTrue(decide(failures: 5, restarts: policy.maxRestarts - 1, since: 9999).isGo)
        XCTAssertFalse(decide(failures: 5, restarts: policy.maxRestarts, since: 9999).isGo)
        XCTAssertFalse(decide(failures: 500, restarts: 99, since: 99999).isGo)
    }

    // MARK: Reasons

    /// The wait reason is logged, so it has to say which guard held.
    func testEachGuardExplainsItself() {
        for (decision, expected) in [
            (decide(failures: 1), "exhausted"),
            (decide(failures: 5, audio: true), "call"),
            (decide(failures: 5, restarts: 99, since: 9999), "cap"),
            (decide(failures: 5, restarts: 1, since: 5), "cooling down"),
        ] {
            guard case .wait(let reason) = decision else { return XCTFail("should wait") }
            XCTAssertTrue(reason.contains(expected), "expected '\(expected)' in: \(reason)")
        }
    }

    /// The first restart has no previous one to cool down from.
    func testFirstRestartIsNotBlockedByAMissingTimestamp() {
        XCTAssertTrue(decide(failures: 3, restarts: 0, since: nil).isGo)
    }

    // MARK: Window recovery by activation

    private func activation(noWindow: Int,
                            activations: Int = 0,
                            since: TimeInterval? = nil,
                            audio: Bool = false,
                            restarting: Bool = false) -> TeamsRestartRecovery.Decision {
        TeamsRestartRecovery.decideActivation(consecutiveNoWindowFailures: noWindow,
                                              activationsSoFar: activations,
                                              secondsSinceLastActivation: since,
                                              audioCaptureActive: audio,
                                              restartInProgress: restarting,
                                              policy: policy)
    }

    /// One poll is not evidence. A window that is merely slow to appear must never be
    /// grabbed at, or the app flashes Teams forward during ordinary startup.
    func testASingleMissingWindowDoesNotActivate() {
        XCTAssertFalse(activation(noWindow: 1).isGo)
    }

    /// Persisting across checks is what separates a lost window from a slow one. The
    /// polite routes have had ~90s each by this point.
    func testActivatesOnceTheConditionPersists() {
        XCTAssertTrue(activation(noWindow: 2).isGo)
        XCTAssertTrue(activation(noWindow: 7).isGo)
    }

    /// Activation is cheaper than a restart — a second of focus, handed straight back —
    /// so it is allowed sooner. It must still be strictly harder to reach than one poll.
    func testActivationIsReachedSoonerThanARestart() {
        XCTAssertLessThan(policy.failuresBeforeActivation, policy.failuresBeforeRestart)
        XCTAssertGreaterThan(policy.failuresBeforeActivation, 1)
    }

    /// Same rule as the restart path: a call outranks recovery, always.
    func testNeverActivatesDuringACall() {
        XCTAssertFalse(activation(noWindow: 99, audio: true).isGo)
        guard case .wait(let reason) = activation(noWindow: 99, audio: true) else {
            return XCTFail("should wait")
        }
        XCTAssertTrue(reason.contains("call"), reason)
    }

    /// The two escalations must not fight each other: a restart already owns the recovery.
    func testDoesNotActivateWhileARestartIsRunning() {
        XCTAssertFalse(activation(noWindow: 99, restarting: true).isGo)
    }

    /// "Do not repeatedly flash Teams in front of the user" — enforced by both a cooldown
    /// and a cap.
    func testActivationIsRateLimited() {
        XCTAssertFalse(activation(noWindow: 5, activations: 1, since: 5).isGo)
        XCTAssertFalse(activation(noWindow: 5, activations: 1, since: policy.activationCooldown - 1).isGo)
        XCTAssertTrue(activation(noWindow: 5, activations: 1, since: policy.activationCooldown + 1).isGo)
    }

    func testActivationGivesUpAtTheCap() {
        XCTAssertTrue(activation(noWindow: 5, activations: policy.maxActivations - 1, since: 9999).isGo)
        XCTAssertFalse(activation(noWindow: 5, activations: policy.maxActivations, since: 9999).isGo)
        XCTAssertFalse(activation(noWindow: 500, activations: 999, since: 99999).isGo)
    }

    /// A loop is the failure mode that would make this worse than the bug: every repeated
    /// attempt must terminate, whatever order the guards are hit in.
    func testRepeatedFailureCannotLoop() {
        var activations = 0
        for _ in 0..<50 where activation(noWindow: 99, activations: activations, since: 9999).isGo {
            activations += 1
        }
        XCTAssertEqual(activations, policy.maxActivations, "activation must stop at the cap")

        var restarts = 0
        for _ in 0..<50 where decide(failures: 99, restarts: restarts, since: 9999).isGo {
            restarts += 1
        }
        XCTAssertEqual(restarts, policy.maxRestarts, "restart must stop at the cap")
    }

    /// Deferring for a call must not consume the budget — otherwise a long meeting would
    /// exhaust recovery without a single attempt having been made.
    func testWaitingForACallDoesNotBurnTheBudget() {
        for _ in 0..<20 {
            XCTAssertFalse(activation(noWindow: 99, activations: 0, audio: true).isGo)
        }
        XCTAssertTrue(activation(noWindow: 99, activations: 0, audio: false).isGo,
                      "recovery must still be available once the call ends")
    }
}
