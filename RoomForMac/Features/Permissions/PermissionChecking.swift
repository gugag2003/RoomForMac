import Foundation

/// Detects and requests one approval.
///
/// Implementations reach the system only through injected closures, so unit tests drive them
/// with scripted answers and never trigger a real prompt.
protocol PermissionChecking: Sendable {
    var id: PermissionID { get }

    /// Reads the current state. Never shows UI or a prompt.
    func currentState() async -> PermissionState

    /// Asks for the approval: may show a system prompt, open System Settings or move the app.
    /// Returns the state right after asking.
    func request() async -> PermissionState
}
