import Darwin
import Foundation
import Testing
@testable import RoomForMac

/// `QuarantineCleanup`: the policy, and `run` over temporary bundles whose files carry the real
/// `com.apple.quarantine` attribute. Only temporary folders are touched, never the running app.
@Suite("Quarantine cleanup", .timeLimit(.minutes(1)))
struct QuarantineCleanupTests {
    /// Held by the suite so the folder outlives every use inside a test.
    let temp: TemporaryDirectory

    init() throws {
        temp = try TemporaryDirectory()
    }

    // MARK: - Policy

    /// The skip key as a build could leave it in Info.plist.
    enum SkipValue: Sendable, CaseIterable {
        case absent, no, yes, lowercaseYes, mixedCaseYes, number, boolean

        var info: [String: Any] {
            let key = QuarantineCleanup.skipInfoKey
            switch self {
            case .absent: return [:]
            case .no: return [key: "NO"]
            case .yes: return [key: "YES"]
            case .lowercaseYes: return [key: "yes"]
            case .mixedCaseYes: return [key: "Yes"]
            case .number: return [key: 1]
            case .boolean: return [key: true]
            }
        }
    }

    private static let locations: [AppLocation] = [.installed, .outsideApplications, .translocated(original: nil)]

    @Test func onlyANormalLaunchOfAnInstalledCopyRuns() {
        let modes: [RuntimeMode] = [.normal, .unitTestHost, .uiTest(.onboarded)]
        var runs: [String] = []
        for mode in modes {
            for location in Self.locations where QuarantineCleanup.shouldRun(mode: mode, location: location, info: [:]) {
                runs.append("\(mode) \(location)")
            }
        }
        #expect(runs == ["normal installed"])
    }

    @Test(arguments: [
        (SkipValue.absent, true), (.no, true), (.yes, false), (.lowercaseYes, false), (.mixedCaseYes, false),
        (.number, true), (.boolean, true),
    ])
    func theSkipKeyStopsTheCleanupOnlyAsTheStringYes(_ skip: SkipValue, _ expected: Bool) {
        #expect(QuarantineCleanup.shouldRun(mode: .normal, location: .installed, info: skip.info) == expected)
    }

    @Test(arguments: SkipValue.allCases)
    func theSkipKeyNeverStartsACleanupThePolicyRefuses(_ skip: SkipValue) {
        #expect(QuarantineCleanup.shouldRun(mode: .unitTestHost, location: .installed, info: skip.info) == false)
        #expect(QuarantineCleanup.shouldRun(mode: .normal, location: .outsideApplications, info: skip.info) == false)
        #expect(QuarantineCleanup.shouldRun(mode: .normal, location: .translocated(original: nil), info: skip.info) == false)
    }

    @Test func theContractIsStable() {
        #expect(QuarantineCleanup.attribute == "com.apple.quarantine")
        #expect(QuarantineCleanup.skipInfoKey == "RFMSkipQuarantineCleanup")
    }

    // MARK: - hasQuarantine

    @Test func hasQuarantineReadsTheItemItself() throws {
        let bundle = try AppBundleFixture.make(in: temp.url, marker: "m")
        let nested = AppBundleFixture.nestedFile(of: bundle)
        #expect(QuarantineCleanup.hasQuarantine(bundle) == false)
        #expect(QuarantineCleanup.hasQuarantine(nested) == false)

        try AppBundleFixture.setQuarantine(on: nested)
        #expect(QuarantineCleanup.hasQuarantine(nested))
        #expect(QuarantineCleanup.hasQuarantine(bundle) == false, "the folder has none of its own")
        #expect(QuarantineCleanup.hasQuarantine(temp.url.appending(path: "missing")) == false)
    }

    // MARK: - run

    @Test func removesTheAttributeEverywhereAndReturnsTrue() async throws {
        let bundle = try AppBundleFixture.make(in: temp.url, marker: "m")
        let executable = bundle.appending(path: "Contents/MacOS/RoomForMac")
        let nested = AppBundleFixture.nestedFile(of: bundle)
        for item in [bundle, executable, nested] {
            try AppBundleFixture.setQuarantine(on: item)
        }

        #expect(await QuarantineCleanup.run(bundleURL: bundle) == true)

        for item in [bundle, executable, nested] {
            #expect(QuarantineCleanup.hasQuarantine(item) == false, "\(item.lastPathComponent) kept the attribute")
        }
        #expect(QuarantineCleanup.quarantinedItems(in: bundle) == 0)
    }

    @Test func findsAnAttributeThatOnlyANestedFileCarries() async throws {
        let bundle = try AppBundleFixture.make(in: temp.url, marker: "m")
        let executable = bundle.appending(path: "Contents/MacOS/RoomForMac")
        try AppBundleFixture.setQuarantine(on: executable)
        #expect(QuarantineCleanup.hasQuarantine(bundle) == false)

        #expect(await QuarantineCleanup.run(bundleURL: bundle) == true)
        #expect(QuarantineCleanup.hasQuarantine(executable) == false)
    }

    @Test func aBundleWithoutTheAttributeReturnsFalseAndStripsNothing() async throws {
        let bundle = try AppBundleFixture.make(in: temp.url, marker: "m")
        let calls = Locked<[URL]>([])

        #expect(await QuarantineCleanup.run(bundleURL: bundle) { calls.append($0) } == false)
        #expect(calls.value.isEmpty, "a clean copy was stripped again")
        #expect(await QuarantineCleanup.run(bundleURL: bundle) == false, "the real strip on a clean bundle")
    }

    @Test func aSecondRunOnACleanedBundleReturnsFalse() async throws {
        let bundle = try AppBundleFixture.make(in: temp.url, marker: "m")
        try AppBundleFixture.setQuarantine(on: AppBundleFixture.nestedFile(of: bundle))
        #expect(await QuarantineCleanup.run(bundleURL: bundle) == true)
        #expect(await QuarantineCleanup.run(bundleURL: bundle) == false)
    }

    @Test func aStripThatThrowsReturnsFalseAndDoesNotPropagate() async throws {
        struct Refused: Error {}
        let bundle = try AppBundleFixture.make(in: temp.url, marker: "m")
        let nested = AppBundleFixture.nestedFile(of: bundle)
        try AppBundleFixture.setQuarantine(on: nested)
        let calls = Locked(0)

        let result = await QuarantineCleanup.run(bundleURL: bundle) { _ in
            calls.mutate { $0 += 1 }
            throw Refused()
        }
        #expect(result == false)
        #expect(calls.value == 1)
        #expect(QuarantineCleanup.hasQuarantine(nested), "nothing was stripped, so the attribute stays")
    }

    @Test func aStripThatRemovesNothingReturnsFalse() async throws {
        let bundle = try AppBundleFixture.make(in: temp.url, marker: "m")
        try AppBundleFixture.setQuarantine(on: AppBundleFixture.nestedFile(of: bundle))
        let calls = Locked<[URL]>([])

        #expect(await QuarantineCleanup.run(bundleURL: bundle) { calls.append($0) } == false)
        #expect(calls.value == [bundle], "the strip gets the bundle folder, once")
    }

    @Test func aMissingBundleReturnsFalseWithoutStripping() async {
        let calls = Locked<[URL]>([])
        let missing = temp.url.appending(path: "Missing.app")
        #expect(await QuarantineCleanup.run(bundleURL: missing) { calls.append($0) } == false)
        #expect(calls.value.isEmpty)
        #expect(await QuarantineCleanup.run(bundleURL: missing) == false)
    }

    @Test func symlinksAreNeverFollowed() async throws {
        let bundle = try AppBundleFixture.make(in: temp.url, marker: "m")
        let outside = temp.url.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: outsideFile)
        try AppBundleFixture.setQuarantine(on: outsideFile)
        let contents = bundle.appending(path: "Contents")
        try FileManager.default.createSymbolicLink(at: contents.appending(path: "linked-folder"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: contents.appending(path: "linked-file"), withDestinationURL: outsideFile)

        // Only the outside file carries the attribute: the bundle itself is clean.
        #expect(QuarantineCleanup.quarantinedItems(in: bundle) == 0)
        #expect(await QuarantineCleanup.run(bundleURL: bundle) == false)
        #expect(QuarantineCleanup.hasQuarantine(outsideFile), "a symlink led the cleanup out of the bundle")

        // With a file inside the bundle to clean, the outside file is still left alone.
        let nested = AppBundleFixture.nestedFile(of: bundle)
        try AppBundleFixture.setQuarantine(on: nested)
        #expect(await QuarantineCleanup.run(bundleURL: bundle) == true)
        #expect(QuarantineCleanup.hasQuarantine(nested) == false)
        #expect(QuarantineCleanup.hasQuarantine(outsideFile), "a symlink led the cleanup out of the bundle")
    }

    @MainActor
    @Test func runsOffTheMainThread() async throws {
        let bundle = try AppBundleFixture.make(in: temp.url, marker: "m")
        try AppBundleFixture.setQuarantine(on: AppBundleFixture.nestedFile(of: bundle))
        let ranOnMain = Locked<Bool?>(nil)

        _ = await QuarantineCleanup.run(bundleURL: bundle) { _ in
            ranOnMain.set(pthread_main_np() != 0)
        }
        #expect(ranOnMain.value == false, "the strip ran on the main thread, so a launch would wait for it")
    }
}
