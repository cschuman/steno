import Foundation
@testable import StenoDaemon

/// Mock implementation of PermissionService for testing.
/// Uses @MainActor to avoid concurrency issues in tests.
@MainActor
final class MockPermissionService: PermissionService {
    /// The status to return from checkPermissions.
    var permissionStatus: PermissionStatus = .granted

    /// The value to return from requestMicrophoneAccess.
    var microphoneAccessGranted = true

    /// Tracks if requestMicrophoneAccess was called.
    private(set) var microphoneAccessRequested = false

    /// Tracks if checkPermissions was called.
    private(set) var permissionsChecked = false

    /// Gates that successive `checkPermissions()` calls park on, one per
    /// call in order, so a test can hold a caller mid-preflight. Calls
    /// past the end of the queue do not park.
    nonisolated let checkGates = GateQueue()

    final class GateQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var gates: [AsyncGate] = []

        func enqueue(_ newGates: AsyncGate...) {
            lock.withLock { gates.append(contentsOf: newGates) }
        }

        fileprivate func next() -> AsyncGate? {
            lock.withLock { gates.isEmpty ? nil : gates.removeFirst() }
        }
    }

    nonisolated func requestMicrophoneAccess() async -> Bool {
        await MainActor.run {
            self.microphoneAccessRequested = true
            return self.microphoneAccessGranted
        }
    }

    nonisolated func checkPermissions() async -> PermissionStatus {
        if let gate = checkGates.next() {
            await gate.wait()
        }
        return await MainActor.run {
            self.permissionsChecked = true
            return self.permissionStatus
        }
    }

    // MARK: - Test Helpers

    /// Resets all state for a new test.
    func reset() {
        permissionStatus = .granted
        microphoneAccessGranted = true
        microphoneAccessRequested = false
        permissionsChecked = false
    }

    /// Configures all permissions as denied.
    func denyAll() {
        permissionStatus = .denied
        microphoneAccessGranted = false
    }

    /// Configures all permissions as granted.
    func grantAll() {
        permissionStatus = .granted
        microphoneAccessGranted = true
    }
}
