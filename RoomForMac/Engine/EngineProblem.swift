import MoleEngine

/// The four `VERSION` values that identify one engine build.
struct EngineFingerprint: Sendable, Equatable {
    var moleTag: String
    var moleCommit: String
    var patchesSHA256: String
    var patchCount: Int

    init(moleTag: String, moleCommit: String, patchesSHA256: String, patchCount: Int) {
        self.moleTag = moleTag
        self.moleCommit = moleCommit
        self.patchesSHA256 = patchesSHA256
        self.patchCount = patchCount
    }

    init(_ version: EngineVersion) {
        self.init(
            moleTag: version.moleTag,
            moleCommit: version.moleCommit,
            patchesSHA256: version.patchesSHA256,
            patchCount: version.patchCount
        )
    }

    /// The engine this build of the app was made with, generated from build/engine/VERSION.
    static var expected: EngineFingerprint {
        EngineFingerprint(
            moleTag: EngineExpectation.moleTag,
            moleCommit: EngineExpectation.moleCommit,
            patchesSHA256: EngineExpectation.patchesSHA256,
            patchCount: EngineExpectation.patchCount
        )
    }

    /// One line of key=value data for details and diagnostics. It is data, not prose, so it is
    /// not localized.
    var summary: String {
        "tag=\(moleTag) commit=\(moleCommit) patches_sha256=\(patchesSHA256) patch_count=\(patchCount)"
    }
}

/// Why the bundled engine cannot be used. Any of these blocks the app behind "Reinstall RoomForMac".
enum EngineProblem: Error, Sendable, Equatable {
    /// A required file is missing or not executable, or `VERSION` is unreadable.
    /// Carries the `EngineError.installationInvalid` message.
    case installationInvalid(String)
    /// `VERSION` in the bundle is not the one this build was made with.
    case versionMismatch(expected: EngineFingerprint, found: EngineFingerprint)
    /// A helper could not run `-h`. `tool` is "analyze-go" or "status-go".
    case selfTestFailed(tool: String, detail: String)
}
