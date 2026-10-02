import XCTest
@testable import AgentPadKit

/// Pins the `SleepGuard.refresh()` state machine across the three-notch
/// dial (off / auto / always): assertion held iff the mode calls for
/// it, create/release exactly balanced, repeated refreshes idempotent, and
/// the privileged lid layer engaged iff (active && helper authorized). The
/// IOKit/pmset calls + live observation loop are seam-injected out; the
/// real assertion path is manual-verify.
@MainActor
final class SleepGuardTests: XCTestCase {
    private var mode: AwakeMode = .auto
    private var running = false
    private var creates = 0
    private var releases = 0

    private func makeGuard(createSucceeds: Bool = true) -> SleepGuard {
        let sleepGuard = SleepGuard()
        sleepGuard.awakeMode = { [weak self] in self?.mode ?? .off }
        sleepGuard.hasActiveWork = { [weak self] in self?.running ?? false }
        sleepGuard.createAssertion = { [weak self] in
            self?.creates += 1
            return createSucceeds ? IOPMAssertionID(42) : nil
        }
        sleepGuard.releaseAssertion = { [weak self] _ in self?.releases += 1 }
        // Lid layer quiet by default; wireLid overrides for lid tests.
        sleepGuard.helperReady = { false }
        sleepGuard.setLidSleep = { _, done in done(true) }
        sleepGuard.onLidHelperFailure = {}
        // Ownership-marker seams write real files in production — no-op
        // them (the opt-in write-seam rule).
        sleepGuard.markOwnership = {}
        sleepGuard.clearOwnership = {}
        return sleepGuard
    }

    // MARK: - Idle-sleep assertion (auto tier)

    func testHoldsWhileBusy() {
        let sleepGuard = makeGuard()
        running = true
        sleepGuard.refresh()
        XCTAssertTrue(sleepGuard.isKeepingAwake)
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(releases, 0)
    }

    func testRefreshIsIdempotentWhileHeld() {
        let sleepGuard = makeGuard()
        running = true
        sleepGuard.refresh()
        sleepGuard.refresh()
        sleepGuard.refresh()
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(releases, 0)
    }

    func testReleasesWhenWorkStops() {
        let sleepGuard = makeGuard()
        running = true
        sleepGuard.refresh()
        running = false
        sleepGuard.refresh()
        XCTAssertFalse(sleepGuard.isKeepingAwake)
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(releases, 1)
    }

    func testReleasesWhenDialedOffMidRun() {
        let sleepGuard = makeGuard()
        running = true
        sleepGuard.refresh()
        mode = .off
        sleepGuard.refresh()
        XCTAssertFalse(sleepGuard.isKeepingAwake)
        XCTAssertEqual(releases, 1)
    }

    func testNeverHoldsWhileOff() {
        let sleepGuard = makeGuard()
        mode = .off
        running = true
        sleepGuard.refresh()
        XCTAssertFalse(sleepGuard.isKeepingAwake)
        XCTAssertEqual(creates, 0)
    }

    func testIdleAgentsDoNotHold() {
        // hasActiveWork is already filtered to running agents / live SSH —
        // attention / failed / idle agents must not keep the Mac awake.
        // This pins the guard's own behavior for the "not busy" input.
        let sleepGuard = makeGuard()
        running = false
        sleepGuard.refresh()
        XCTAssertFalse(sleepGuard.isKeepingAwake)
        XCTAssertEqual(creates, 0)
    }

    func testCreateFailureIsRetriedNextRefresh() {
        let sleepGuard = makeGuard(createSucceeds: false)
        running = true
        sleepGuard.refresh()
        XCTAssertFalse(sleepGuard.isKeepingAwake)
        XCTAssertEqual(creates, 1)
        // Still wanted, still not held → the next refresh tries again.
        sleepGuard.refresh()
        XCTAssertEqual(creates, 2)
        XCTAssertEqual(releases, 0)
    }

    // MARK: - Privileged lid layer

    /// Wires the lid seams onto a guard: recorded calls, controllable
    /// success, synchronous completion (mirrors the main-actor hop).
    private func wireLid(
        _ sleepGuard: SleepGuard,
        helperReady: @escaping () -> Bool,
        succeeds: @escaping () -> Bool = { true }
    ) -> (calls: () -> [Bool], failures: () -> Int) {
        var calls: [Bool] = []
        var failures = 0
        sleepGuard.helperReady = { helperReady() }
        sleepGuard.setLidSleep = { disabled, done in
            calls.append(disabled)
            done(succeeds())
        }
        sleepGuard.onLidHelperFailure = { failures += 1 }
        return ({ calls }, { failures })
    }

    func testLidEngagesAndReleasesAroundBusy() {
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { true })
        running = true
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true])
        XCTAssertTrue(sleepGuard.lidSleepDisabled)
        running = false
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true, false])
        XCTAssertFalse(sleepGuard.lidSleepDisabled)
    }

    func testNoHelperNeverCallsLid() {
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { false })
        running = true
        sleepGuard.refresh()
        running = false
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [])
    }

    func testHelperRemovalMidBusyReleasesWithoutDroppingAssertion() {
        var helper = true
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { helper })
        running = true
        sleepGuard.refresh()
        XCTAssertTrue(sleepGuard.lidSleepDisabled)
        helper = false
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true, false])
        XCTAssertFalse(sleepGuard.lidSleepDisabled)
        // The idle-sleep assertion survives the lid-layer drop.
        XCTAssertTrue(sleepGuard.isKeepingAwake)
        XCTAssertEqual(releases, 0)
    }

    func testLidEngageFailureReportsAndDoesNotRetryStorm() {
        // The failure handler here deliberately does NOT step the dial —
        // pinning the internal engage-block: one failed attempt per busy
        // window, no retry loop even if the handler misbehaves. (The real
        // handler steps `always` down; the completion re-runs refresh, so
        // without the block this would recurse to a crash.)
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { true }, succeeds: { false })
        running = true
        sleepGuard.refresh()
        XCTAssertFalse(sleepGuard.lidSleepDisabled)
        XCTAssertEqual(lid.failures(), 1)
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true], "engage must not retry within the same busy window")
        // Work ends → block clears → the next busy window may try again.
        running = false
        sleepGuard.refresh()
        running = true
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true, true])
    }

    func testReleaseFailureKeepsClaimingEngagedState() {
        // A failed `off` most likely leaves the system at SleepDisabled 1:
        // AgentPad must keep claiming it (so shutdown cleanup stays armed)
        // and must not retry-loop; the next poll that CONFIRMS the state
        // lifts the block for one calm retry per poll cycle.
        var succeed = true
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { true }, succeeds: { succeed })
        running = true
        sleepGuard.refresh()
        XCTAssertTrue(sleepGuard.lidSleepDisabled)
        succeed = false
        running = false
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true, false])
        XCTAssertTrue(sleepGuard.lidSleepDisabled, "failed release keeps the engaged claim")
        // No instant retry storm.
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true, false])
        // Poll confirms reality (still disabled system-wide) → one retry,
        // this time the helper works again.
        succeed = true
        sleepGuard.reconcileExternalLidState(systemDisabled: true)
        XCTAssertEqual(lid.calls(), [true, false, false])
        XCTAssertFalse(sleepGuard.lidSleepDisabled)
    }

    func testLidRefreshIsIdempotentWhileEngaged() {
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { true })
        running = true
        sleepGuard.refresh()
        sleepGuard.refresh()
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true])
    }

    // MARK: - Always tier

    func testAlwaysHoldsEverythingWithoutBusy() {
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { true })
        mode = .always
        running = false
        sleepGuard.refresh()
        XCTAssertTrue(sleepGuard.isKeepingAwake)
        XCTAssertEqual(lid.calls(), [true])
        // Step down with nothing running → everything releases.
        mode = .auto
        sleepGuard.refresh()
        XCTAssertFalse(sleepGuard.isKeepingAwake)
        XCTAssertEqual(lid.calls(), [true, false])
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(releases, 1)
    }

    func testAlwaysWithoutHelperStillHoldsAssertion() {
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { false })
        mode = .always
        sleepGuard.refresh()
        XCTAssertTrue(sleepGuard.isKeepingAwake)
        XCTAssertEqual(lid.calls(), [])
    }

    // MARK: - External-change reconciliation

    func testExternalOffDropsAlwaysToOffAndBlocksReengage() {
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { true })
        sleepGuard.setMode = { [weak self] in self?.mode = $0 }
        mode = .always
        running = true
        sleepGuard.refresh()
        XCTAssertTrue(sleepGuard.lidSleepDisabled)
        // User runs `sudo pmset -a disablesleep 0` in some terminal — an
        // explicit veto: everything stands down, not just the lid layer
        // (Auto would re-arm on the next busy window, fighting the user).
        sleepGuard.reconcileExternalLidState(systemDisabled: false)
        XCTAssertEqual(mode, .off, "external release vetoes the dial to off")
        XCTAssertFalse(sleepGuard.lidSleepDisabled)
        XCTAssertFalse(sleepGuard.isKeepingAwake)
        XCTAssertEqual(releases, 1)
        // Manually dialing back to auto is a NEW explicit intent — auto
        // semantics resume in full, lid included.
        mode = .auto
        sleepGuard.refresh()
        XCTAssertTrue(sleepGuard.isKeepingAwake)
        XCTAssertEqual(lid.calls(), [true, true])
    }

    func testExternalOffDuringAutoBusyDoesNotReengageThisWindow() {
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { true })
        sleepGuard.setMode = { [weak self] in self?.mode = $0 }
        mode = .auto
        running = true
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true])
        // AgentPad engaged the lid for this busy window; the user shuts it off
        // externally. The dial stays on auto (only Always is vetoed down),
        // the idle assertion stays, but AgentPad must not immediately re-grab
        // what the user just released.
        sleepGuard.reconcileExternalLidState(systemDisabled: false)
        XCTAssertEqual(mode, .auto)
        XCTAssertTrue(sleepGuard.isKeepingAwake)
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true], "vetoed for the rest of this busy window")
        // A fresh busy window re-engages normally.
        running = false
        sleepGuard.refresh()
        running = true
        sleepGuard.refresh()
        XCTAssertEqual(lid.calls(), [true, true])
    }

    func testExternalOnSurfacesAsAlways() {
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { true })
        sleepGuard.setMode = { [weak self] in self?.mode = $0 }
        mode = .auto
        running = false
        sleepGuard.refresh()
        XCTAssertFalse(sleepGuard.isKeepingAwake)
        // User (or another tool) enables disablesleep externally.
        sleepGuard.reconcileExternalLidState(systemDisabled: true)
        XCTAssertEqual(mode, .always, "external engage surfaces as the Always notch")
        XCTAssertTrue(sleepGuard.lidSleepDisabled)
        // The refresh absorbs it: assertion joins, no redundant lid call.
        XCTAssertTrue(sleepGuard.isKeepingAwake)
        XCTAssertEqual(lid.calls(), [])
    }

    func testReconcileMatchingStateIsANoOp() {
        let sleepGuard = makeGuard()
        _ = wireLid(sleepGuard, helperReady: { true })
        var modeChanges = 0
        sleepGuard.setMode = { [weak self] in self?.mode = $0; modeChanges += 1 }
        sleepGuard.reconcileExternalLidState(systemDisabled: false)
        XCTAssertEqual(modeChanges, 0)
        XCTAssertEqual(creates, 0)
    }

    func testStepDownFromAlwaysKeepsHoldingWhileBusy() {
        let sleepGuard = makeGuard()
        let lid = wireLid(sleepGuard, helperReady: { true })
        mode = .always
        running = true
        sleepGuard.refresh()
        // always → when-busy with work still running: nothing releases.
        mode = .auto
        sleepGuard.refresh()
        XCTAssertTrue(sleepGuard.isKeepingAwake)
        XCTAssertTrue(sleepGuard.lidSleepDisabled)
        XCTAssertEqual(lid.calls(), [true])
        XCTAssertEqual(releases, 0)
    }

    // MARK: - Status-light pulse token

    /// The light plays one bounded pulse per dial change and is otherwise
    /// still — a continuous animation keeps the whole display compositing at
    /// full refresh rate (#39). Only a *real* change may bump the token: the
    /// Settings picker re-sets the current mode on any re-render, and a
    /// no-op that pulsed would leave the light flashing for no reason.
    ///
    /// `off`/`auto` are the safe notches to drive here — `always` would run
    /// the privileged-helper install and pop an admin prompt. The model is a
    /// local instance and `scheduleSave` only holds it weakly, so the pending
    /// 300ms write finds a deallocated self and never touches the real
    /// `~/.agentpad/settings.json`.
    func testDialPulseBumpsOnlyOnRealChange() {
        let model = AgentPadSettingsModel()
        model.awakeMode = .off
        model.awakeDialPulse = 0

        model.applyAwakeMode(.auto)
        XCTAssertEqual(model.awakeDialPulse, 1, "a real dial change must pulse the light")

        model.applyAwakeMode(.auto)
        model.applyAwakeMode(.auto)
        XCTAssertEqual(model.awakeDialPulse, 1, "re-setting the same mode must not pulse")

        model.applyAwakeMode(.off)
        XCTAssertEqual(model.awakeDialPulse, 2, "changing back must pulse again")
    }
}
