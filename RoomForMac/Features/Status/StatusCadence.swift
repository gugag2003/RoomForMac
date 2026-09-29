/// Something on screen that wants Status readings (Ruling 16). `StatusMonitor` keeps
/// the set of active demands and runs its one `status-go` at the cadence they resolve to.
enum StatusDemand: Hashable, Sendable {
    /// The Status section is on screen in a visible window.
    case statusSection
    /// The menu-bar extra's panel is open.
    case menuBarPanel
    /// The menu-bar extra is in the menu bar. Its label is a static symbol with no numbers.
    case menuBarInserted
}

/// How the one `status-go` runs. The cases are ordered: a later case is faster.
enum StatusCadence: Int, Comparable, Sendable {
    /// Suspended. After five minutes paused, the process ends.
    case paused
    /// Resumed for one snapshot every 10 s. Reserved: `resolve` never returns it in M2, but
    /// `StatusMonitor` still supports it.
    case background
    /// Resumed: a snapshot about every 2 s.
    case live

    /// The cadence for a set of demands. Nothing runs before onboarding is complete and the
    /// engine is ready (`isAllowed`). The Status section or the open panel is live.
    ///
    /// The menu-bar extra alone pauses the collector (Ruling 16, revised): its label shows
    /// no live numbers, and a resumed `status-go` answers within about 0.5 s of the panel
    /// opening, which saves about 3 % of a core all day. Spec §4.4's 10 s polling while only
    /// the menu bar is shown comes back by returning `.background` on the marked line.
    static func resolve(demands: Set<StatusDemand>, isAllowed: Bool) -> StatusCadence {
        guard isAllowed else {
            return .paused
        }
        if demands.contains(.statusSection) || demands.contains(.menuBarPanel) {
            return .live
        }
        if demands.contains(.menuBarInserted) {
            return .paused  // Ruling 16: `.background` re-enables spec §4.4's 10 s polling.
        }
        return .paused
    }

    static func < (lhs: StatusCadence, rhs: StatusCadence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
