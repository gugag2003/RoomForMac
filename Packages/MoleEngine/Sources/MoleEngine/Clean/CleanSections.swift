import Foundation

/// The section names `bin/clean.sh` announces with `section` events, in the
/// order `run_clean_sections` runs them (Mole V1.56.0). The names are plain
/// English and never localized by the engine; hosts localize titles
/// themselves and must still accept a name they do not know.
public enum CleanSections {
    /// Only with a sudo session, which `MOLE_NO_AUTH=1` never grants.
    static let system = "System"
    /// Only on Apple silicon (`IS_M_SERIES`, `uname -m` is `arm64`).
    static let appleSiliconUpdates = "Apple Silicon updates"

    /// Every section a whole-home dry run announces, in order.
    public static func expected(appleSilicon: Bool, administrator: Bool) -> [String] {
        var names: [String] = []
        if administrator {
            names.append(system)
        }
        names += [
            "User essentials", "App caches", "Browsers", "Cloud & Office", "Developer tools",
            "Apps & utilities", "Virtualization", "Application Support", "App leftovers",
        ]
        if appleSilicon {
            names.append(appleSiliconUpdates)
        }
        names += ["Device backups & firmware", "Time Machine", "Large files", "Project artifacts"]
        return names
    }

    /// Sections that only print a report on stdout and never produce `item`
    /// rows, although they take time.
    public static let reportOnly: Set<String> = ["Large files", "Project artifacts"]

    /// Sections whose rows a normal user can never remove: a real run can
    /// only report them `failed`. Hosts show these rows as needing a password.
    public static let administratorOnly: Set<String> = ["Time Machine"]

    /// Whether the engine runs on Apple silicon, so "Apple Silicon updates"
    /// appears. RoomForMac ships arm64 only; the Intel branch keeps the
    /// package testable anywhere.
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}
