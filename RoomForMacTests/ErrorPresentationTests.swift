import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Error presentation")
struct ErrorPresentationTests {
    // MARK: Engine problems

    @Test func anInvalidInstallationAsksForAReinstall() {
        let presentation = ErrorPresentation(EngineProblem.installationInvalid("missing bin/clean.sh"))
        #expect(presentation.title == "RoomForMac needs to be reinstalled")
        #expect(presentation.message == "Some files RoomForMac needs are missing or damaged.")
        #expect(presentation.details == "missing bin/clean.sh")
    }

    @Test func aVersionMismatchShowsBothFingerprints() {
        let expected = EngineFingerprint(moleTag: "V1.56.0", moleCommit: "aaa", patchesSHA256: "bbb", patchCount: 5)
        let found = EngineFingerprint(moleTag: "V0.0.0", moleCommit: "ccc", patchesSHA256: "none", patchCount: 0)
        let presentation = ErrorPresentation(EngineProblem.versionMismatch(expected: expected, found: found))
        #expect(presentation.title == "RoomForMac needs to be reinstalled")
        #expect(presentation.message == "The engine inside RoomForMac doesn't match this version of the app.")
        #expect(presentation.details == """
        Expected: tag=V1.56.0 commit=aaa patches_sha256=bbb patch_count=5
        Found: tag=V0.0.0 commit=ccc patches_sha256=none patch_count=0
        """)
    }

    @Test func aFailedSelfTestNamesTheTool() {
        let presentation = ErrorPresentation(EngineProblem.selfTestFailed(tool: "status-go", detail: "Signal 9"))
        #expect(presentation.title == "RoomForMac needs to be reinstalled")
        #expect(presentation.message == "Part of RoomForMac's engine couldn't run. macOS may have blocked it, or the app is damaged.")
        #expect(presentation.details == "status-go\nSignal 9")
    }

    // MARK: Engine errors, one test per case

    @Test func engineInstallationInvalid() {
        let presentation = ErrorPresentation(EngineError.installationInvalid("not executable: bin/status-go"))
        #expect(presentation.title == "RoomForMac needs to be reinstalled")
        #expect(presentation.message == "Some files RoomForMac needs are missing or damaged.")
        #expect(presentation.details == "not executable: bin/status-go")
    }

    @Test func engineLaunchFailedNamesTheExecutable() {
        let error = EngineError.launchFailed(executable: "/Applications/RoomForMac.app/Contents/Resources/engine/bin/status-go", reason: "failed(13)")
        let presentation = ErrorPresentation(error)
        #expect(presentation.title == "The engine couldn't start")
        #expect(presentation.message == "RoomForMac couldn't start status-go.")
        #expect(presentation.details == "/Applications/RoomForMac.app/Contents/Resources/engine/bin/status-go\nfailed(13)")
    }

    @Test func engineNonZeroExitKeepsTheStderrTail() {
        let presentation = ErrorPresentation(EngineError.nonZeroExit(code: 2, stderrTail: "rm: /x: Operation not permitted\n"))
        #expect(presentation.title == "The engine ran into a problem")
        #expect(presentation.message == "It stopped with error code 2.")
        #expect(presentation.details == "Exit code 2\nrm: /x: Operation not permitted")
    }

    @Test func engineTerminatedBySignalKeepsTheStderrTail() {
        let presentation = ErrorPresentation(EngineError.terminatedBySignal(15, stderrTail: "stopping"))
        #expect(presentation.title == "The engine stopped unexpectedly")
        #expect(presentation.message == "macOS ended it before it finished.")
        #expect(presentation.details == "Signal 15\nstopping")
    }

    @Test func engineTerminatedBySignalWithoutOutputStillNamesTheSignal() {
        #expect(ErrorPresentation(EngineError.terminatedBySignal(9, stderrTail: "")).details == "Signal 9")
    }

    @Test func engineTimedOut() {
        let presentation = ErrorPresentation(EngineError.timedOut)
        #expect(presentation.title == "The engine took too long")
        #expect(presentation.message == "RoomForMac stopped it after waiting too long. Try again.")
        #expect(presentation.details == "timedOut")
    }

    @Test func engineCancelled() {
        let presentation = ErrorPresentation(EngineError.cancelled)
        #expect(presentation.title == "Stopped")
        #expect(presentation.message == "The engine was stopped before it finished.")
        #expect(presentation.details == "cancelled")
    }

    @Test func engineMalformedOutput() {
        let presentation = ErrorPresentation(EngineError.malformedOutput("no JSON array in output"))
        #expect(presentation.title == "The engine returned something unexpected")
        #expect(presentation.message == "RoomForMac couldn't read the engine's answer.")
        #expect(presentation.details == "no JSON array in output")
    }

    // MARK: Other errors

    @Test func taskCancellationReadsAsStopped() {
        #expect(ErrorPresentation(CancellationError()) == ErrorPresentation(EngineError.cancelled))
    }

    @Test func decodingErrorsAreUnexpectedAnswers() throws {
        struct Level: Decodable { let path: String }
        let error = try #require(throws: DecodingError.self) {
            try JSONDecoder().decode(Level.self, from: Data(#"{"path": 5}"#.utf8))
        }
        let presentation = ErrorPresentation(error)
        #expect(presentation.title == "The engine returned something unexpected")
        #expect(presentation.message == "RoomForMac couldn't read the engine's answer.")
        #expect(presentation.details.hasPrefix("path: "))
    }

    @Test func fileErrorsNameThePath() {
        let error = CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: "/private/tmp/roomformac-engine-1/events.ndjson"])
        let presentation = ErrorPresentation(error)
        #expect(presentation.title == "RoomForMac couldn't use a file")
        #expect(presentation.message == "RoomForMac couldn't use the file at /private/tmp/roomformac-engine-1/events.ndjson.")
        #expect(presentation.details.hasPrefix("NSCocoaErrorDomain 257\n"))
    }

    @Test func fileErrorsWithoutAPathStillExplain() {
        let presentation = ErrorPresentation(CocoaError(.fileWriteOutOfSpace))
        #expect(presentation.title == "RoomForMac couldn't use a file")
        #expect(presentation.message == "RoomForMac couldn't use a file it needs.")
    }

    @Test func anyOtherErrorIsSomethingWentWrong() {
        struct Unexpected: Error {}
        let presentation = ErrorPresentation(Unexpected())
        #expect(presentation.title == "Something went wrong")
        #expect(presentation.message == "RoomForMac ran into an unexpected problem.")
        #expect(presentation.details.contains("Unexpected"))
    }

    @Test func aLocalizedErrorKeepsItsOwnDescription() {
        struct Described: LocalizedError {
            var errorDescription: String? { "The disk is not mounted." }
        }
        let presentation = ErrorPresentation(Described())
        #expect(presentation.title == "Something went wrong")
        #expect(presentation.message == "The disk is not mounted.")
    }

    // MARK: Diagnostics

    @Test func diagnosticsCarryTheVersionsAndTheExpectedEngine() {
        let presentation = ErrorPresentation(EngineProblem.selfTestFailed(tool: "analyze-go", detail: "Exit code 2\nboom"))
        let report = presentation.diagnostics(appVersion: "0.1.0 (1)", osVersion: "27.0.0")
        let expected = EngineFingerprint.expected
        #expect(report.contains("RoomForMac needs to be reinstalled"))
        #expect(report.contains(presentation.message))
        #expect(report.contains("analyze-go\nExit code 2\nboom"))
        #expect(report.contains("App 0.1.0 (1)"))
        #expect(report.contains("macOS 27.0.0"))
        #expect(report.contains(expected.moleTag))
        #expect(report.contains(expected.moleCommit))
        #expect(report.contains(expected.patchesSHA256))
        #expect(report.contains("patch_count=\(expected.patchCount)"))
    }

    @Test func diagnosticsAddNoPathsOfTheirOwn() {
        let report = ErrorPresentation(EngineError.timedOut).diagnostics(appVersion: "0.1.0 (1)", osVersion: "27.0.0")
        #expect(!report.contains(NSHomeDirectory()))
        #expect(!report.contains(Bundle.main.bundlePath))
    }

    @Test func versionsAreFormattedForTheReport() {
        #expect(ErrorPresentation.appVersion(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]) == "0.1.0 (1)")
        #expect(ErrorPresentation.appVersion(info: nil) == "? (?)")
        #expect(ErrorPresentation.osVersion(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)) == "27.0.1")
    }
}
