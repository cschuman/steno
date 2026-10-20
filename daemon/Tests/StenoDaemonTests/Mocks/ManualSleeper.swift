import Foundation

/// A sleep closure the test drives by hand.
///
/// Every call records the requested `Duration` and then suspends until the
/// test calls `fire()`. Honours the engine's sleep contract: a cancelled
/// caller is resumed with `CancellationError` straight away, so a timer
/// loop cancelled by the engine unwinds without the test's help.
final class ManualSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var nextID = 0
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var cancelledBeforeSuspend: Set<Int> = []
    private var _requested: [Duration] = []

    /// Every duration the engine asked to sleep for, in order.
    var requested: [Duration] {
        lock.lock(); defer { lock.unlock() }
        return _requested
    }

    /// Callers currently suspended waiting for `fire()`.
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiters.count
    }

    /// The closure to inject as the engine's sleep.
    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await self.wait(duration) }
    }

    /// Resume every suspended caller normally.
    func fire() {
        lock.lock()
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        for (_, continuation) in resumed {
            continuation.resume()
        }
    }

    private func wait(_ duration: Duration) async throws {
        let id = lock.withLock {
            let id = nextID
            nextID += 1
            _requested.append(duration)
            return id
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if cancelledBeforeSuspend.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let continuation = waiters.removeValue(forKey: id) {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else {
                cancelledBeforeSuspend.insert(id)
                lock.unlock()
            }
        }
    }
}

/// Wall clock the test advances by hand, for the engine's `now:` hook.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// A one-shot barrier a mock can park a call on until the test opens it.
///
/// Deliberately ignores cancellation for the purpose of resuming (real
/// hardware bring-up does not stop mid-call because a task was
/// cancelled), but records that the cancellation arrived so a test can
/// tell when a concurrent `stop()` / `pause()` has reached its wait.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var _arrivals = 0
    private var _sawCancellation = false

    /// Calls that have reached the gate so far.
    var arrivals: Int {
        lock.lock(); defer { lock.unlock() }
        return _arrivals
    }

    /// Whether a parked caller's task was cancelled while waiting.
    var sawCancellation: Bool {
        lock.lock(); defer { lock.unlock() }
        return _sawCancellation
    }

    func wait() async {
        let alreadyOpen = lock.withLock {
            _arrivals += 1
            return isOpen
        }
        if alreadyOpen { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            _sawCancellation = true
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in resumed {
            continuation.resume()
        }
    }
}
