import Testing
import Foundation
@testable import StenoDaemon

/// Tests for automatic recovery out of the `.error` state (#109).
///
/// The always-on plan's "Engine-state recovery from `error`" section lists
/// three triggers. Trigger 1 (pause/resume) already existed, and #112 added
/// wake. These tests cover triggers 2 and 3: an audio device change and a
/// coarse periodic re-attempt. Both run a full
/// rebuild through the same helper the wake path uses, because U5's
/// restart machinery cannot leave `.error` on its own.
///
/// The timer is driven by `ManualSleeper`, so a "firing" is an explicit
/// `fire()` and nothing happens between firings. The clock is a
/// `ManualClock`, which the rate limit (one attempt per interval,
/// whichever trigger) reads.
@Suite("Error Recovery Tests (#109)")
struct ErrorRecoveryTests {

    typealias MockPowerAssertion = SleepWakeHandlerTests.MockPowerAssertion

    struct Harness {
        let engine: RecordingEngine
        let repo: MockTranscriptRepository
        let audioFactory: MockAudioSourceFactory
        let recognizerFactory: MockSpeechRecognizerFactory
        let permissions: MockPermissionService
        let delegate: MockRecordingEngineDelegate
        let sleeper: ManualSleeper
        let clock: ManualClock
        let power: MockPowerAssertion
    }

    // MARK: - Engine assembly

    @MainActor
    private func makeEngine(
        interval: Duration = .seconds(60),
        heal: Int = 30
    ) -> Harness {
        let repo = MockTranscriptRepository()
        let perms = MockPermissionService()
        let af = MockAudioSourceFactory()
        let rf = MockSpeechRecognizerFactory()
        let del = MockRecordingEngineDelegate()
        let sleeper = ManualSleeper()
        let clock = ManualClock()
        let power = MockPowerAssertion()
        let coordinator = RollingSummaryCoordinator(
            repository: repo,
            summarizer: MockSummarizationService(),
            triggerCount: 100,
            timeThreshold: 3600
        )
        // U12 prune disabled so closed and interrupted sessions stay
        // visible for inspection, as in the sleep/wake suite.
        let engine = RecordingEngine(
            repository: repo,
            permissionService: perms,
            summaryCoordinator: coordinator,
            audioSourceFactory: af,
            speechRecognizerFactory: rf,
            delegate: del,
            backoffSleep: { _ in try Task.checkCancellation() },
            powerAssertion: power,
            deviceUIDProvider: { "BuiltInMic" },
            healThresholdSeconds: heal,
            now: { clock.now },
            emptySessionMinChars: 0,
            emptySessionMinDurationSeconds: 0,
            retentionDays: 0,
            errorRecoveryInterval: interval,
            errorRecoverySleep: sleeper.sleep
        )
        return Harness(
            engine: engine,
            repo: repo,
            audioFactory: af,
            recognizerFactory: rf,
            permissions: perms,
            delegate: del,
            sleeper: sleeper,
            clock: clock,
            power: power
        )
    }

    // MARK: - Helpers

    private func waitFor(
        timeout: Duration = .seconds(3),
        step: Duration = .milliseconds(5),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let comps = timeout.components
        let deadline = Date().addingTimeInterval(
            TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) / 1e18
        )
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: step)
        }
        return false
    }

    /// Surrender the way #118 did: the mic recognizer fails with the same
    /// error until U5's budget is spent. Not a permission surrender, and
    /// the session stays as the recovery anchor.
    @discardableResult
    private func surrenderViaU5(_ h: Harness, expectLoop: Bool = true) async throws -> Session {
        for _ in 0..<6 {
            let failing = MockSpeechRecognizerHandle()
            failing.errorToThrow = NSError(domain: "ErrorRecoveryTest", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ErrorRecoveryTest#1"
            ])
            h.recognizerFactory.enqueueMicHandle(failing)
        }
        let session = try await h.engine.start()
        let surrendered = await waitFor {
            let exhausted = await h.delegate.recoveryExhaustedReasons.count == 1
            let status = await h.engine.status
            return exhausted && status == .error
        }
        #expect(surrendered, "precondition: U5 must surrender")
        #expect(await h.engine.currentSession?.id == session.id, "precondition: a surrender keeps the anchor")
        if expectLoop {
            let armed = await waitFor { h.sleeper.pendingCount == 1 }
            #expect(armed, "precondition: the recovery loop must be sleeping")
        }
        return session
    }

    /// Fire the timer once and wait until that firing has been handled:
    /// either the loop went back to sleep, or the engine left `.error`.
    @discardableResult
    private func fireAndSettle(_ h: Harness) async -> Bool {
        let before = h.sleeper.requested.count
        h.sleeper.fire()
        return await waitFor {
            if h.sleeper.requested.count > before { return true }
            return await h.engine.status != .error
        }
    }

    /// Run `operation` in its own task and return a flag that is set when
    /// it finishes. Lets a race test wait for "parked OR returned" with a
    /// bound instead of awaiting a task that might never finish.
    private func launch(_ operation: @escaping @Sendable () async -> Void) -> DoneFlag {
        let flag = DoneFlag()
        Task {
            await operation()
            flag.set()
        }
        return flag
    }

    private var injectedMicFailure: Error {
        MockAudioSourceFactory.InjectedError("mic still down")
    }

    // MARK: - 1. Timer recovers once the fault clears

    @Test("Timer firing recovers a U5 surrender: .recording, assertion re-taken, same session")
    func timerRecoversU5Surrender() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        let session = try await surrenderViaU5(h)
        #expect(!h.power.isAcquired)

        // The fault is gone: the recognizer queue is empty, so the next
        // bring-up gets a healthy handle.
        await fireAndSettle(h)

        #expect(await h.engine.status == .recording)
        #expect(h.power.isAcquired, "the power assertion must be re-taken")
        #expect(await h.engine.currentSession?.id == session.id, "gap under the heal threshold reuses the session")
        #expect(h.audioFactory.liveMicSources == 1)
        let reasons = await h.delegate.recoveringReasons
        #expect(reasons.contains("error-recovery:timer:gap=0s"))

        await h.engine.stop()
    }

    // MARK: - 2. Configured interval

    @Test("The loop sleeps for the configured interval")
    func loopSleepsForConfiguredInterval() async throws {
        let h = await makeEngine(interval: .seconds(45), heal: 30)
        try await surrenderViaU5(h)

        #expect(h.sleeper.requested == [.seconds(45)])

        await h.engine.stop()
    }

    // MARK: - 3. Hard-down

    @Test("Hard-down: each firing makes one bounded attempt and stays in .error; nothing happens between firings")
    func hardDownRetriesOncePerFiring() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await surrenderViaU5(h)
        let baseline = h.audioFactory.micCreateCount

        h.audioFactory.micError = injectedMicFailure
        await fireAndSettle(h)
        #expect(await h.engine.status == .error)
        #expect(h.audioFactory.micCreateCount == baseline + 1, "exactly one rebuild per firing")

        // No firing, no attempt.
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.audioFactory.micCreateCount == baseline + 1)

        h.clock.advance(by: 61)
        h.audioFactory.micError = injectedMicFailure
        await fireAndSettle(h)
        #expect(await h.engine.status == .error)
        #expect(h.audioFactory.micCreateCount == baseline + 2, "the next firing tries again")
        #expect(h.audioFactory.liveMicSources == 0)

        await h.engine.stop()
    }

    // MARK: - 4. Permission surrender gates the timer

    @Test("After a permission surrender, timer firings make no attempt")
    func permissionSurrenderBlocksTimer() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        h.audioFactory.systemAudioSource.errorToThrow = SystemAudioError.permissionDenied
        _ = try await h.engine.start(systemAudio: true)
        #expect(await h.engine.status == .error)
        #expect(await waitFor { h.sleeper.pendingCount == 1 })
        let baseline = h.audioFactory.micCreateCount

        // Even with the grant restored, the timer does not act on a
        // permission surrender.
        h.audioFactory.systemAudioSource.errorToThrow = nil
        #expect(await fireAndSettle(h), "the loop must run the firing and sleep again")
        h.clock.advance(by: 61)
        #expect(await fireAndSettle(h), "the loop must run the firing and sleep again")

        #expect(await h.engine.status == .error)
        #expect(h.audioFactory.micCreateCount == baseline)

        await h.engine.stop()
    }

    // MARK: - 5. Mic preflight

    @Test("Mic preflight: a firing makes no attempt while the microphone grant reads as denied")
    func micPreflightBlocksAttempt() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await surrenderViaU5(h)
        let baseline = h.audioFactory.micCreateCount

        await MainActor.run { h.permissions.permissionStatus = .denied }
        await fireAndSettle(h)

        #expect(await h.engine.status == .error)
        #expect(h.audioFactory.micCreateCount == baseline)
        let asked = await MainActor.run { h.permissions.microphoneAccessRequested }
        #expect(!asked, "recovery must never prompt")

        await h.engine.stop()
    }

    // MARK: - 6. Interval 0 disables everything

    @Test("Interval 0: no timer, and a device change in .error takes the old U5 path")
    func zeroIntervalDisablesRecovery() async throws {
        let h = await makeEngine(interval: .zero, heal: 30)
        try await surrenderViaU5(h, expectLoop: false)

        await h.engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)

        #expect(h.sleeper.requested.isEmpty, "the sleeper must never be called")
        // The old path schedules a U5 restart against the exhausted
        // policy, which surrenders again.
        let secondSurrender = await waitFor {
            await h.delegate.recoveryExhaustedReasons.count == 2
        }
        #expect(secondSurrender)
        #expect(await h.engine.status == .error)
        let reasons = await h.delegate.recoveringReasons
        #expect(!reasons.contains { $0.hasPrefix("error-recovery:") })

        await h.engine.stop()
    }

    // MARK: - 7. stop() from .error

    @Test("stop() in .error ends .idle, closes the anchor row, and later firings make no attempt")
    func stopFromError() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        let session = try await surrenderViaU5(h)
        let baseline = h.audioFactory.micCreateCount

        await h.engine.stop()

        #expect(await h.engine.status == .idle)
        #expect(await h.engine.currentSession == nil)
        let row = try await h.repo.session(session.id)
        #expect(row?.status == .completed, "stop must close the anchor session row")
        #expect(h.sleeper.pendingCount == 0, "the loop must be cancelled")

        h.clock.advance(by: 61)
        h.sleeper.fire()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.audioFactory.micCreateCount == baseline)
        #expect(await h.engine.status == .idle)
    }

    // MARK: - 8. pause() from .error

    @Test("pause() in .error: no attempt while paused")
    func pauseFromErrorBlocksAttempts() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await surrenderViaU5(h)
        let baseline = h.audioFactory.micCreateCount

        try await h.engine.pause(autoResumeSeconds: nil)

        #expect(await h.engine.status == .paused)
        #expect(h.sleeper.pendingCount == 0)
        h.clock.advance(by: 61)
        h.sleeper.fire()
        await h.engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.audioFactory.micCreateCount == baseline)
        #expect(await h.engine.status == .paused)
        #expect(h.audioFactory.liveMicSources == 0)

        await h.engine.stop()
    }

    // MARK: - 9. Sleep and wake

    @Test("willSleep in .error cancels the loop; didWake re-arms it when still .error")
    func sleepCancelsAndWakeRearms() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await surrenderViaU5(h)

        await h.engine.handleSystemWillSleep()
        #expect(await waitFor { h.sleeper.pendingCount == 0 }, "willSleep must cancel the loop")

        // The fault is still there at wake, so the wake rebuild fails and
        // the engine stays in `.error`.
        h.audioFactory.micError = injectedMicFailure
        await h.engine.handleSystemDidWake()

        #expect(await h.engine.status == .error)
        #expect(await waitFor { h.sleeper.pendingCount == 1 }, "didWake must re-arm the loop")

        await h.engine.stop()
    }

    // MARK: - 10. Rollover past the heal threshold

    @Test("Gap past the heal threshold rolls the session over")
    func longGapRollsOver() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        let original = try await surrenderViaU5(h)

        h.clock.advance(by: 120)
        await fireAndSettle(h)

        #expect(await h.engine.status == .recording)
        let current = await h.engine.currentSession
        #expect(current != nil)
        #expect(current?.id != original.id, "a new session id after rollover")
        let originalRow = try await h.repo.session(original.id)
        #expect(originalRow?.status == .interrupted)
        let reasons = await h.delegate.recoveringReasons
        #expect(reasons.contains("error-recovery:timer:gap=120s"))

        await h.engine.stop()
    }

    // MARK: - 11. Failed attempt keeps the anchor

    @Test("A failed attempt keeps the anchor, so the next firing can still recover")
    func failedAttemptKeepsAnchor() async throws {
        // Heal threshold above the 61 s the clock advances, so the second
        // firing reuses the anchor instead of rolling it over.
        let h = await makeEngine(interval: .seconds(60), heal: 300)
        let session = try await surrenderViaU5(h)

        h.audioFactory.micError = injectedMicFailure
        await fireAndSettle(h)
        #expect(await h.engine.status == .error)
        #expect(await h.engine.currentSession?.id == session.id, "the anchor must survive a failed bring-up")

        h.clock.advance(by: 61)
        await fireAndSettle(h)
        #expect(await h.engine.status == .recording)
        #expect(await h.engine.currentSession?.id == session.id)

        await h.engine.stop()
    }

    // MARK: - 12. No anchor, no retry

    @Test(".error with no session: firings make no attempt")
    func errorWithoutSessionDoesNotRetry() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        // A mic failure inside start's bring-up runs `cleanup()`, which
        // drops the session: `.error` with nothing to recover into.
        h.audioFactory.micError = injectedMicFailure
        _ = try? await h.engine.start()
        #expect(await h.engine.status == .error)
        #expect(await h.engine.currentSession == nil)
        #expect(await waitFor { h.sleeper.pendingCount == 1 })
        let baseline = h.audioFactory.micCreateCount

        await fireAndSettle(h)
        h.clock.advance(by: 61)
        await h.engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)

        #expect(h.audioFactory.micCreateCount == baseline)
        #expect(await h.engine.status == .error)
        #expect(try await h.repo.allSessions().count == 1, "no session may be opened")

        await h.engine.stop()
    }

    // MARK: - 13. Device change recovers immediately

    @Test("Device change in .error recovers immediately with no firing")
    func deviceChangeRecoversImmediately() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        let session = try await surrenderViaU5(h)

        await h.engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)

        #expect(await h.engine.status == .recording)
        #expect(await h.engine.currentSession?.id == session.id)
        #expect(h.sleeper.requested.count == 1, "the timer never fired")
        let reasons = await h.delegate.recoveringReasons
        #expect(reasons.contains { $0.hasPrefix("error-recovery:device-change:gap=") })
        // No extra surrender from the old U5 path.
        #expect(await h.delegate.recoveryExhaustedReasons.count == 1)

        await h.engine.stop()
    }

    // MARK: - 14. Device-change rate limit

    @Test("Device changes are rate limited to one attempt per interval")
    func deviceChangeRateLimited() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await surrenderViaU5(h)
        let baseline = h.audioFactory.micCreateCount

        h.audioFactory.micError = injectedMicFailure
        await h.engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)
        #expect(h.audioFactory.micCreateCount == baseline + 1)
        #expect(await h.engine.status == .error)

        // Headset renegotiation churn inside the interval does nothing.
        h.clock.advance(by: 30)
        await h.engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)
        await h.engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)
        #expect(h.audioFactory.micCreateCount == baseline + 1)
        #expect(await h.delegate.recoveryExhaustedReasons.count == 1)

        h.clock.advance(by: 31)
        await h.engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)
        #expect(h.audioFactory.micCreateCount == baseline + 2)
        #expect(await h.engine.status == .recording)

        await h.engine.stop()
    }

    // MARK: - 15. Device change after a permission surrender

    @Test("Device change after a permission surrender still attempts and recovers")
    func deviceChangeAfterPermissionSurrenderRecovers() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        h.audioFactory.systemAudioSource.errorToThrow = SystemAudioError.permissionDenied
        let session = try await h.engine.start(systemAudio: true)
        #expect(await h.engine.status == .error)

        h.audioFactory.systemAudioSource.errorToThrow = nil
        await h.engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)

        #expect(await h.engine.status == .recording)
        #expect(await h.engine.currentSession?.id == session.id)
        #expect(await h.engine.isSystemAudioEnabled)
        #expect(h.audioFactory.liveMicSources == 1, "the surviving mic pipeline must be torn down first")

        await h.engine.stop()
    }

    // MARK: - 16-18. Lifecycle commands racing an in-flight attempt

    /// Park a timer attempt inside `makeMicrophoneSource` and return once
    /// it is there.
    private func parkAttemptMidBringUp(_ h: Harness, gate: AsyncGate) async throws {
        try await surrenderViaU5(h)
        h.audioFactory.micGate = gate
        h.sleeper.fire()
        let parked = await waitFor { gate.arrivals == 1 }
        #expect(parked, "precondition: the attempt must be suspended mid-bring-up")
    }

    @Test("pause() during an in-flight attempt ends .paused with no pipeline and no later attempt")
    func pauseDuringInFlightAttempt() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        let gate = AsyncGate()
        try await parkAttemptMidBringUp(h, gate: gate)

        let engine = h.engine
        let pauseTask = Task { try await engine.pause(autoResumeSeconds: nil) }
        #expect(await waitFor { gate.sawCancellation }, "pause must cancel and wait for the attempt")
        gate.open()
        try await pauseTask.value

        #expect(await h.engine.status == .paused)
        #expect(h.audioFactory.liveMicSources == 0, "no pipeline may outlive the pause")
        #expect(!h.power.isAcquired)
        #expect(h.sleeper.pendingCount == 0, "the loop must be gone, so the firing below proves nothing runs")
        let baseline = h.audioFactory.micCreateCount
        h.clock.advance(by: 61)
        h.sleeper.fire()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.audioFactory.micCreateCount == baseline)
        #expect(await h.engine.status == .paused)

        await h.engine.stop()
    }

    @Test("stop() during an in-flight attempt ends .idle with no pipeline and no later attempt")
    func stopDuringInFlightAttempt() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        let gate = AsyncGate()
        try await parkAttemptMidBringUp(h, gate: gate)

        let engine = h.engine
        let stopTask = Task { await engine.stop() }
        #expect(await waitFor { gate.sawCancellation }, "stop must cancel and wait for the attempt")
        gate.open()
        await stopTask.value

        #expect(await h.engine.status == .idle)
        #expect(h.audioFactory.liveMicSources == 0)
        #expect(!h.power.isAcquired)
        #expect(h.sleeper.pendingCount == 0, "the loop must be gone, so the firing below proves nothing runs")
        let baseline = h.audioFactory.micCreateCount
        h.clock.advance(by: 61)
        h.sleeper.fire()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.audioFactory.micCreateCount == baseline)
        #expect(await h.engine.status == .idle)
    }

    @Test("start() during an in-flight attempt leaves exactly one live mic pipeline")
    func startDuringInFlightAttempt() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        let gate = AsyncGate()
        try await parkAttemptMidBringUp(h, gate: gate)

        let engine = h.engine
        let startTask = Task { () -> Result<Session, Error> in
            do { return .success(try await engine.start()) } catch { return .failure(error) }
        }
        #expect(await waitFor { gate.sawCancellation }, "start must cancel and wait for the attempt")
        gate.open()
        let outcome = await startTask.value

        switch outcome {
        case .success:
            break
        case .failure(let error):
            #expect(error as? RecordingEngineError == .alreadyRecording)
        }
        #expect(await h.engine.status == .recording)
        #expect(h.audioFactory.liveMicSources == 1, "no leaked second mic pipeline")

        await h.engine.stop()
        #expect(h.audioFactory.liveMicSources == 0)
    }

    // MARK: - 19. Wake rebuild failing after a stop

    @Test("A wake rebuild that fails after stop() landed does not restore the anchor")
    func failedWakeAfterStopDoesNotRestoreAnchor() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await surrenderViaU5(h)

        await h.engine.handleSystemWillSleep()
        let gate = AsyncGate()
        h.audioFactory.micGate = gate
        h.audioFactory.micError = injectedMicFailure

        let engine = h.engine
        let wakeTask = Task { await engine.handleSystemDidWake() }
        #expect(await waitFor { gate.arrivals == 1 }, "precondition: wake must be mid-bring-up")

        // stop() does not wait for a wake rebuild.
        await h.engine.stop()
        #expect(await h.engine.status == .idle)

        gate.open()
        await wakeTask.value
        #expect(await h.engine.currentSession == nil, "the anchor must not come back after the user stopped")

        // The failed wake re-entered `.error` after the stop (the known
        // wake/stop limitation), so a loop is armed. That makes the firing
        // below a real one: it runs and finds no anchor.
        #expect(await h.engine.status == .error)
        #expect(await waitFor { h.sleeper.pendingCount == 1 }, "the firing below must reach a sleeping loop")
        let baseline = h.audioFactory.micCreateCount
        h.clock.advance(by: 61)
        #expect(await fireAndSettle(h), "the loop must run the firing and sleep again")
        h.clock.advance(by: 61)
        await h.engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)
        #expect(h.audioFactory.micCreateCount == baseline, "no attempt may follow a stop")
        #expect(h.audioFactory.liveMicSources == 0)

        await h.engine.stop()
    }
    // MARK: - 20-22. Device change while a lifecycle command drains the loop

    /// The interleaving the verifier found. The timer attempt parks in its
    /// mic preflight (gate `timer`). `command` starts, cancels the loop and
    /// waits for it. A device change arrives and parks in its own preflight
    /// (gate `device`), and that preflight resumes first. If the device
    /// change gets through, its bring-up parks on `mic` so it is still in
    /// flight when `command` finishes. Every wait is bounded, and every
    /// gate is opened before returning, so nothing can hang.
    ///
    /// On the fix the device change is refused before its preflight, so it
    /// never parks on `device` or `mic`; the waits below accept "returned"
    /// as well as "parked" for that reason.
    @discardableResult
    private func raceDeviceChangeAgainst(
        _ h: Harness,
        command: @escaping @Sendable (RecordingEngine) async -> Void
    ) async throws -> Session {
        let anchor = try await surrenderViaU5(h)
        let timer = AsyncGate()
        let device = AsyncGate()
        let mic = AsyncGate()
        defer {
            timer.open()
            device.open()
            mic.open()
        }
        h.permissions.checkGates.enqueue(timer, device)
        h.audioFactory.micGate = mic

        h.sleeper.fire()
        #expect(await waitFor { timer.arrivals == 1 }, "precondition: the timer attempt parks in its preflight")

        let engine = h.engine
        let commandDone = launch { await command(engine) }
        #expect(await waitFor { timer.sawCancellation }, "precondition: the command is waiting on the loop")

        let deviceDone = launch {
            await engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)
        }
        #expect(await waitFor { device.arrivals == 1 || deviceDone.isSet })
        device.open()
        #expect(await waitFor { mic.arrivals == 1 || deviceDone.isSet })

        timer.open()
        #expect(await waitFor { commandDone.isSet }, "the command must finish")
        mic.open()
        #expect(await waitFor { deviceDone.isSet }, "the device change must finish")
        h.audioFactory.micGate = nil
        try await Task.sleep(for: .milliseconds(50))
        return anchor
    }

    @Test("A device change while stop() waits on the loop cannot record after the stop")
    func deviceChangeDuringStopDrain() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await raceDeviceChangeAgainst(h) { await $0.stop() }

        #expect(await h.engine.status == .idle)
        #expect(h.audioFactory.liveMicSources == 0)
        #expect(!h.power.isAcquired)
        #expect(h.sleeper.pendingCount == 0, "no loop may be armed after the stop")
        let baseline = h.audioFactory.micCreateCount
        h.clock.advance(by: 61)
        h.sleeper.fire()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.audioFactory.micCreateCount == baseline)
        #expect(await h.engine.status == .idle)

        await h.engine.stop()
    }

    @Test("A device change while pause() waits on the loop cannot record after the pause")
    func deviceChangeDuringPauseDrain() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        let anchor = try await raceDeviceChangeAgainst(h) { try? await $0.pause(autoResumeSeconds: nil) }

        #expect(await h.engine.status == .paused)
        #expect(h.audioFactory.liveMicSources == 0)
        #expect(!h.power.isAcquired)
        let row = try await h.repo.session(anchor.id)
        #expect(row?.pausedIndefinitely == true, "pause state must be persisted on the anchor row")
        #expect(h.sleeper.pendingCount == 0, "no loop may be armed while paused")

        await h.engine.stop()
    }

    @Test("A device change while willSleep waits on the loop leaves no capture; wake brings up exactly one mic")
    func deviceChangeDuringSleepDrain() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await raceDeviceChangeAgainst(h) { await $0.handleSystemWillSleep() }

        #expect(h.audioFactory.liveMicSources == 0, "nothing may capture across the sleep")
        #expect(await h.engine.status != .recording)

        await h.engine.handleSystemDidWake()
        #expect(await h.engine.status == .recording)
        #expect(h.audioFactory.liveMicSources == 1)

        await h.engine.stop()
    }

    // MARK: - 23. Device change during pause()'s teardown

    @Test("A device change during pause()'s teardown makes no attempt")
    func deviceChangeDuringPauseTeardown() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        // A system-audio permission surrender keeps the mic pipeline, so
        // pause has a mic stop to park in.
        h.audioFactory.systemAudioSource.errorToThrow = SystemAudioError.permissionDenied
        _ = try await h.engine.start(systemAudio: true)
        #expect(await h.engine.status == .error)
        #expect(h.audioFactory.liveMicSources == 1, "precondition: the mic pipeline survived")
        h.audioFactory.systemAudioSource.errorToThrow = nil

        let stopGate = AsyncGate()
        defer { stopGate.open() }
        h.audioFactory.micStopGate = stopGate
        let baseline = h.audioFactory.micCreateCount

        let engine = h.engine
        let pauseDone = launch { try? await engine.pause(autoResumeSeconds: nil) }
        #expect(await waitFor { stopGate.arrivals == 1 }, "precondition: pause is parked in its teardown")
        #expect(await h.engine.status == .error, "precondition: .paused is not set yet")

        // If the device change got through, its attempt would park on the
        // same stop gate while tearing down.
        let deviceDone = launch {
            await engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)
        }
        #expect(await waitFor { stopGate.arrivals == 2 || deviceDone.isSet })

        stopGate.open()
        #expect(await waitFor { pauseDone.isSet }, "pause must finish")
        #expect(await waitFor { deviceDone.isSet }, "the device change must finish")
        try await Task.sleep(for: .milliseconds(50))

        #expect(h.audioFactory.micCreateCount == baseline, "no attempt may start during pause")
        #expect(await h.engine.status == .paused)
        #expect(h.audioFactory.liveMicSources == 0)

        await h.engine.stop()
    }

    // MARK: - 24. Interval 0 keeps a failed wake's old behavior

    @Test("Interval 0: a failed wake rebuild leaves no session, as before #109")
    func zeroIntervalFailedWakeDropsSession() async throws {
        let h = await makeEngine(interval: .zero, heal: 30)
        try await surrenderViaU5(h, expectLoop: false)

        await h.engine.handleSystemWillSleep()
        h.audioFactory.micError = injectedMicFailure
        await h.engine.handleSystemDidWake()

        #expect(await h.engine.status == .error)
        #expect(await h.engine.currentSession == nil)

        await h.engine.stop()
    }

    // MARK: - 25-27. Two lifecycle commands overlapping an in-flight attempt

    /// Socket commands run concurrently, so a second command can arrive
    /// while the first is still waiting for an attempt. The attempt parks
    /// mid-bring-up on the mic gate, `first` starts and waits for it, then
    /// `second` arrives. `second` must wait for the same attempt: if it
    /// acted while the attempt was parked, the attempt's tail could claim
    /// `.recording` after it. Which waiter resumes first is not
    /// guaranteed, so the checks below hold for either order.
    private func overlapCommands(
        _ h: Harness,
        first: @escaping @Sendable (RecordingEngine) async -> Void,
        second: @escaping @Sendable (RecordingEngine) async -> Void
    ) async throws {
        let gate = AsyncGate()
        defer { gate.open() }
        try await parkAttemptMidBringUp(h, gate: gate)

        let engine = h.engine
        let firstDone = launch { await first(engine) }
        #expect(await waitFor { gate.sawCancellation }, "precondition: the first command is waiting for the attempt")

        let secondDone = launch { await second(engine) }
        let secondReturnedEarly = await waitFor(timeout: .milliseconds(300)) { secondDone.isSet }
        #expect(!secondReturnedEarly, "the second command must wait for the parked attempt")

        gate.open()
        #expect(await waitFor { firstDone.isSet && secondDone.isSet }, "both commands must finish")
        h.audioFactory.micGate = nil
        try await Task.sleep(for: .milliseconds(50))
    }

    /// Live capture matches the status once everything has settled, and a
    /// final `stop()` reaches whatever is running.
    private func expectConsistentCaptureThenStop(_ h: Harness) async {
        let status = await h.engine.status
        #expect(h.audioFactory.liveMicSources == (status == .recording ? 1 : 0), "status \(status)")
        await h.engine.stop()
        #expect(await h.engine.status == .idle)
        #expect(h.audioFactory.liveMicSources == 0, "a final stop must reach every pipeline")
    }

    @Test("start() waiting on an attempt, then stop(): the stop waits too and nothing records after it")
    func overlapStartThenStop() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await overlapCommands(
            h,
            first: { _ = try? await $0.start() },
            second: { await $0.stop() }
        )
        await expectConsistentCaptureThenStop(h)
    }

    @Test("stop() waiting on an attempt, then start(): the start waits too and no mic is orphaned")
    func overlapStopThenStart() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await overlapCommands(
            h,
            first: { await $0.stop() },
            second: { _ = try? await $0.start() }
        )
        await expectConsistentCaptureThenStop(h)
    }

    @Test("willSleep waiting on an attempt, then stop(), then wake: nothing is left stuck or orphaned")
    func overlapSleepThenStopThenWake() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await overlapCommands(
            h,
            first: { await $0.handleSystemWillSleep() },
            second: { await $0.stop() }
        )
        await h.engine.handleSystemDidWake()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.engine.status != .recovering, "wake must not leave the engine stuck in .recovering")
        await expectConsistentCaptureThenStop(h)
    }

    // MARK: - 28. An attempt cancelled in its teardown skips the rebuild

    @Test("An attempt cancelled during its teardown makes no rebuild")
    func attemptCancelledInTeardownSkipsRebuild() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        // A system-audio permission surrender keeps the mic pipeline, so
        // the attempt's teardown has a mic stop to park in.
        h.audioFactory.systemAudioSource.errorToThrow = SystemAudioError.permissionDenied
        _ = try await h.engine.start(systemAudio: true)
        #expect(await h.engine.status == .error)
        #expect(h.audioFactory.liveMicSources == 1, "precondition: the mic pipeline survived")
        h.audioFactory.systemAudioSource.errorToThrow = nil

        let stopGate = AsyncGate()
        defer { stopGate.open() }
        h.audioFactory.micStopGate = stopGate

        let engine = h.engine
        let deviceDone = launch {
            await engine.handleAudioDeviceChange(deviceUID: "BuiltInMic", format: nil)
        }
        #expect(await waitFor { stopGate.arrivals == 1 }, "precondition: the attempt is parked in its teardown")

        let baseline = h.audioFactory.micCreateCount
        let pauseDone = launch { try? await engine.pause(autoResumeSeconds: nil) }
        #expect(await waitFor { stopGate.sawCancellation }, "precondition: pause cancelled the attempt and waits for it")

        stopGate.open()
        #expect(await waitFor { pauseDone.isSet && deviceDone.isSet }, "both must finish")
        try await Task.sleep(for: .milliseconds(50))

        #expect(await h.engine.status == .paused)
        #expect(h.audioFactory.liveMicSources == 0)
        #expect(h.audioFactory.micCreateCount == baseline, "a cancelled attempt must not open the mic")

        await h.engine.stop()
    }

    // MARK: - 29-30. A rejected command does not cost a failed wake its anchor

    /// Record, sleep, then park the wake rebuild in its mic bring-up with a
    /// failure queued behind the gate. The engine sits in `.recovering`
    /// while parked, so `start()` and `resume()` are both rejected.
    private func rejectedCommandDuringFailingWake(
        _ h: Harness,
        command: @escaping @Sendable (RecordingEngine) async throws -> Void
    ) async throws {
        let session = try await h.engine.start()
        await h.engine.handleSystemWillSleep()
        #expect(await h.engine.status == .recovering)

        let gate = AsyncGate()
        defer { gate.open() }
        h.audioFactory.micGate = gate
        h.audioFactory.micError = injectedMicFailure

        let engine = h.engine
        let wakeDone = launch { await engine.handleSystemDidWake() }
        #expect(await waitFor { gate.arrivals == 1 }, "precondition: wake must be mid-bring-up")

        await #expect(throws: RecordingEngineError.self) { try await command(engine) }

        gate.open()
        #expect(await waitFor { wakeDone.isSet }, "wake must finish")
        h.audioFactory.micGate = nil

        #expect(await h.engine.status == .error)
        #expect(await h.engine.currentSession?.id == session.id, "a rejected command must not cost the anchor")

        await h.engine.stop()
    }

    @Test("A start() rejected during a failing wake rebuild does not stop the anchor restore")
    func rejectedStartKeepsWakeAnchor() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await rejectedCommandDuringFailingWake(h) { engine in
            do {
                _ = try await engine.start()
            } catch {
                #expect(error as? RecordingEngineError == .alreadyRecording)
                throw error
            }
        }
    }

    @Test("A resume() rejected during a failing wake rebuild does not stop the anchor restore")
    func rejectedResumeKeepsWakeAnchor() async throws {
        let h = await makeEngine(interval: .seconds(60), heal: 30)
        try await rejectedCommandDuringFailingWake(h) { try await $0.resume() }
    }
}

/// Set once by a launched task when it finishes.
final class DoneFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var isSet: Bool { lock.withLock { done } }

    func set() { lock.withLock { done = true } }
}
