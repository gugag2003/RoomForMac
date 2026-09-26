import Foundation

/// The engine build's VERSION file, written by scripts/build-engine.sh.
public struct EngineVersion: Sendable, Equatable {
    public var moleTag: String
    public var moleCommit: String
    public var patchesSHA256: String
    public var patchCount: Int

    init(parsing text: String) throws {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let tag = values["mole_tag"], !tag.isEmpty,
              let commit = values["mole_commit"], !commit.isEmpty
        else {
            throw EngineError.installationInvalid("VERSION is missing mole_tag or mole_commit")
        }
        moleTag = tag
        moleCommit = commit
        patchesSHA256 = values["patches_sha256"] ?? "none"
        patchCount = Int(values["patch_count"] ?? "") ?? 0
    }
}
