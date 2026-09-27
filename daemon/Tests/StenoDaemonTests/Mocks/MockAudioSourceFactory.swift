import AVFoundation
@testable import StenoDaemon

/// Mock factory that returns configurable audio sources.
final class MockAudioSourceFactory: AudioSourceFactory, @unchecked Sendable {
    /// Test-only error type used by the throw-injection helpers below.
    struct InjectedError: Error, Equatable {
        let message: String
        init(_ message: String = "injected") { self.message = message }
    }

    /// Continuation for the most recently produced mic stream. Earlier
    /// streams are still alive in their own continuations on the engine
    /// side, but `finishMicStream` / `emitMicBuffer` always operate on
    /// the latest one — matching the engine's "tear down old, bring up
    /// fresh" semantics.
    private var micContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// All mic continuations produced so far (one per `makeMicrophoneSource`
    /// call), in order. Lets U5 tests address an earlier rebuild's
    /// stream after a restart has produced a new one.
    private var allMicContinuations: [AsyncStream<AVAudioPCMBuffer>.Continuation] = []

    /// Error to throw from makeMicrophoneSource on the next call.
    /// Cleared after one shot so a follow-up restart can succeed.
    var micError: Error?

    /// Sequence of errors to throw from successive `makeMicrophoneSource`
    /// calls. Each call dequeues the next entry; when empty, the call
    /// returns a real stream. Used by U5 tests that exercise the
    /// "rebuild throws → reschedule" path on multiple consecutive
    /// rebuild attempts before success.
    var micErrorQueue: [Error] = []

    /// Total mic source creations (rebuild count).
    private(set) var micCreateCount: Int = 0

    /// When set, every `makeMicrophoneSource` call parks on this gate
    /// before doing anything else, so a test can hold a bring-up
    /// mid-flight and race a lifecycle command against it.
    var micGate: AsyncGate?

    /// When set, every mic source's stop closure parks on this gate
    /// before stopping, so a test can hold a teardown mid-flight.
    var micStopGate: AsyncGate?

    private let liveLock = NSLock()
    private var nextMicSourceID = 0
    private var liveMicSourceIDs: Set<Int> = []

    /// Mic sources handed out and not yet stopped. A value above 1 means
    /// the engine leaked a capture pipeline. Stopping the same source
    /// twice (two teardowns overlapping on one stop closure) counts once.
    var liveMicSources: Int {
        liveLock.withLock { liveMicSourceIDs.count }
    }

    /// The mock system audio source returned by makeSystemAudioSource.
    let systemAudioSource = MockAudioSource(name: "Mock System Audio", sourceType: .systemAudio)

    /// Track calls.
    private(set) var micSourceCreated = false
    private(set) var systemSourceCreated = false
    private(set) var lastDevice: String?

    /// Default mic format: 16kHz mono.
    let micFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    func makeMicrophoneSource(device: String?) async throws
        -> (buffers: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat, stop: @Sendable () async -> Void) {
        if let micGate {
            await micGate.wait()
        }
        micSourceCreated = true
        lastDevice = device
        micCreateCount += 1

        // The queue takes precedence over the single-shot `micError`
        // so a sequence of rebuild failures can be staged.
        if !micErrorQueue.isEmpty {
            let next = micErrorQueue.removeFirst()
            throw next
        }

        if let error = micError {
            // One-shot: clear so that the next call (e.g. a U5 restart)
            // can succeed against a fresh stream.
            micError = nil
            throw error
        }

        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.micContinuation = continuation
        self.allMicContinuations.append(continuation)

        let sourceID = liveLock.withLock {
            let id = nextMicSourceID
            nextMicSourceID += 1
            liveMicSourceIDs.insert(id)
            return id
        }
        let stop: @Sendable () async -> Void = { [continuation, self] in
            if let gate = self.micStopGate {
                await gate.wait()
            }
            continuation.finish()
            _ = self.liveLock.withLock { self.liveMicSourceIDs.remove(sourceID) }
        }

        return (buffers: stream, format: micFormat, stop: stop)
    }

    func makeSystemAudioSource() -> AudioSource {
        systemSourceCreated = true
        return systemAudioSource
    }

    // MARK: - Test Helpers

    /// Emit a mic buffer to the latest mic stream.
    func emitMicBuffer(_ buffer: AVAudioPCMBuffer) {
        nonisolated(unsafe) let unsafeBuffer = buffer
        micContinuation?.yield(unsafeBuffer)
    }

    /// Finish the latest mic stream.
    func finishMicStream() {
        micContinuation?.finish()
        micContinuation = nil
    }
}
