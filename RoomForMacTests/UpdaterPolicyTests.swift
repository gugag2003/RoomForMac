import Foundation
import Testing
@testable import RoomForMac

/// `UpdaterPolicy`: when the updater may run (Ruling 7). Pure, so every combination is a case.
@Suite("Updater policy")
struct UpdaterPolicyTests {
    private static let executable = "/Applications/RoomForMac.app/Contents/MacOS/RoomForMac"
    private static let feed = "https://example.com/appcast.xml"

    private static let configured = DistributionInfo(infoDictionary: [
        DistributionInfo.feedURLKey: feed, DistributionInfo.publicKeyKey: "cHVibGljLWtleQ==",
    ])
    private static let withoutKey = DistributionInfo(infoDictionary: [
        DistributionInfo.feedURLKey: feed, DistributionInfo.publicKeyKey: "",
    ])

    // MARK: - The whole matrix

    /// One way this process could have been started.
    struct Case: Sendable, CustomTestStringConvertible {
        enum Build: Sendable, CaseIterable { case release, debug, debugOptedIn }

        let mode: RuntimeMode
        let build: Build
        let isConfigured: Bool
        let location: AppLocation

        var arguments: [String] {
            build == .debugOptedIn
                ? [UpdaterPolicyTests.executable, UpdaterPolicy.debugOptInArgument, "YES"]
                : [UpdaterPolicyTests.executable]
        }

        var isDebugBuild: Bool {
            build != .release
        }

        var distribution: DistributionInfo {
            isConfigured ? UpdaterPolicyTests.configured : UpdaterPolicyTests.withoutKey
        }

        var testDescription: String {
            "\(mode), \(build), \(isConfigured ? "configured" : "no key"), \(location)"
        }

        /// The first failing condition, in the documented order, written as a list rather than
        /// as the policy's own early returns.
        var expected: UpdaterAvailability {
            let failing: [UpdaterUnavailableReason?] = [
                mode == .normal ? nil : .testing,
                build == .debug ? .debugBuild : nil,
                isConfigured ? nil : .notConfigured,
                location == .installed ? nil : .notInstalled,
            ]
            return failing.compactMap { $0 }.first.map { .unavailable($0) } ?? .active
        }

        static let all: [Case] = {
            let modes: [RuntimeMode] = [.normal, .unitTestHost, .uiTest(.onboarded)]
            let locations: [AppLocation] = [.installed, .outsideApplications, .translocated(original: nil)]
            var cases: [Case] = []
            for mode in modes {
                for build in Build.allCases {
                    for isConfigured in [true, false] {
                        for location in locations {
                            cases.append(Case(mode: mode, build: build, isConfigured: isConfigured, location: location))
                        }
                    }
                }
            }
            return cases
        }()
    }

    @Test(arguments: Case.all)
    func everyCombinationGivesTheFirstFailingCondition(_ input: Case) {
        let result = UpdaterPolicy.availability(
            mode: input.mode,
            isDebugBuild: input.isDebugBuild,
            arguments: input.arguments,
            distribution: input.distribution,
            location: input.location
        )
        #expect(result == input.expected)
    }

    @Test func theMatrixCoversEveryCombination() {
        #expect(Case.all.count == 3 * 3 * 2 * 3)
        let active = Case.all.filter { $0.expected == .active }
        #expect(active.count == 2, "only .normal, installed, configured, in a release or an opted-in debug build")
        for reason in UpdaterUnavailableReason.allCases {
            #expect(Case.all.contains { $0.expected == .unavailable(reason) }, "no case gives \(reason)")
        }
    }

    // MARK: - The documented order, as literals

    private func availability(
        mode: RuntimeMode = .normal,
        isDebugBuild: Bool = false,
        arguments: [String] = [UpdaterPolicyTests.executable],
        distribution: DistributionInfo = UpdaterPolicyTests.configured,
        location: AppLocation = .installed
    ) -> UpdaterAvailability {
        UpdaterPolicy.availability(
            mode: mode, isDebugBuild: isDebugBuild, arguments: arguments, distribution: distribution, location: location
        )
    }

    @Test func aReleaseBuildOfAnInstalledConfiguredAppIsActive() {
        #expect(availability() == .active)
    }

    @Test func testingWinsOverEverythingElse() {
        for mode in [RuntimeMode.unitTestHost, .uiTest(.onboarding), .uiTest(.engineBroken)] {
            #expect(
                availability(mode: mode, isDebugBuild: true, distribution: Self.withoutKey, location: .outsideApplications)
                    == .unavailable(.testing)
            )
            #expect(availability(mode: mode) == .unavailable(.testing), "a release build of the test host")
        }
    }

    @Test func aDebugBuildWinsOverAMissingKeyAndAnotherLocation() {
        #expect(
            availability(isDebugBuild: true, distribution: Self.withoutKey, location: .outsideApplications)
                == .unavailable(.debugBuild)
        )
    }

    @Test func aMissingKeyWinsOverAnotherLocation() {
        #expect(
            availability(distribution: Self.withoutKey, location: .translocated(original: nil))
                == .unavailable(.notConfigured)
        )
    }

    @Test func aCopyOutsideApplicationsOrTranslocatedIsNotInstalled() {
        let original = URL(fileURLWithPath: "/Users/test/Downloads/RoomForMac.app")
        #expect(availability(location: .outsideApplications) == .unavailable(.notInstalled))
        #expect(availability(location: .translocated(original: nil)) == .unavailable(.notInstalled))
        #expect(availability(location: .translocated(original: original)) == .unavailable(.notInstalled))
    }

    // MARK: - Configuration

    @Test func anHTTPFeedOrAMissingFeedOrAnEmptyKeyIsNotConfigured() {
        let http = DistributionInfo(infoDictionary: [
            DistributionInfo.feedURLKey: "http://example.com/appcast.xml", DistributionInfo.publicKeyKey: "key",
        ])
        let noFeed = DistributionInfo(infoDictionary: [DistributionInfo.publicKeyKey: "key"])
        let spaces = DistributionInfo(infoDictionary: [
            DistributionInfo.feedURLKey: Self.feed, DistributionInfo.publicKeyKey: "  \n ",
        ])
        for distribution in [http, noFeed, spaces, Self.withoutKey] {
            #expect(availability(distribution: distribution) == .unavailable(.notConfigured))
        }
    }

    // MARK: - The DEBUG opt-in

    @Test(arguments: ["YES", "yes", "Yes", "true", "TRUE", "True", "1"])
    func aDebugBuildStartsWhenTheFlagIsFollowedByAYesValue(_ value: String) {
        let arguments = [Self.executable, UpdaterPolicy.debugOptInArgument, value]
        #expect(UpdaterPolicy.optsIn(arguments: arguments))
        #expect(availability(isDebugBuild: true, arguments: arguments) == .active)
    }

    @Test(arguments: ["NO", "no", "false", "0", "", "2", "on", "y", "YES please"])
    func anyOtherValueKeepsADebugBuildOff(_ value: String) {
        let arguments = [Self.executable, UpdaterPolicy.debugOptInArgument, value]
        #expect(UpdaterPolicy.optsIn(arguments: arguments) == false)
        #expect(availability(isDebugBuild: true, arguments: arguments) == .unavailable(.debugBuild))
    }

    @Test func theFlagNeedsItsValueRightAfterIt() {
        let flag = UpdaterPolicy.debugOptInArgument
        #expect(UpdaterPolicy.optsIn(arguments: [Self.executable, flag]) == false)
        #expect(UpdaterPolicy.optsIn(arguments: [Self.executable, "YES", flag]) == false)
        #expect(UpdaterPolicy.optsIn(arguments: [Self.executable, "YES"]) == false)
        #expect(UpdaterPolicy.optsIn(arguments: []) == false)
        #expect(UpdaterPolicy.optsIn(arguments: [Self.executable, "-Other", "1", flag, "true", "-More"]))
    }

    @Test func theFlagChangesNothingInAReleaseBuild() {
        for value in ["YES", "NO"] {
            let arguments = [Self.executable, UpdaterPolicy.debugOptInArgument, value]
            #expect(availability(isDebugBuild: false, arguments: arguments) == .active)
        }
    }

    @Test func theOptInAcceptsTheValuesTheMoveStepFlagAccepts() {
        // Ruling 7: "parsed like -RFMForceMoveStep". Both flags must change together.
        let values = ["YES", "yes", "Yes", "true", "TRUE", "1", "NO", "no", "false", "0", "", "2", "on", "y"]
        for value in values {
            let moveStepForced = !AppLocationChecker.bypassesMoveStep(
                arguments: [Self.executable, AppLocationChecker.forceMoveStepArgument, value], isDebugBuild: true
            )
            let updaterEnabled = UpdaterPolicy.optsIn(arguments: [Self.executable, UpdaterPolicy.debugOptInArgument, value])
            #expect(updaterEnabled == moveStepForced, "the two opt-ins disagree about \"\(value)\"")
        }
    }

    @Test func theContractIsStable() {
        #expect(UpdaterPolicy.debugOptInArgument == "-RFMEnableUpdater")
        #expect(UpdaterUnavailableReason.allCases.map(\.rawValue) == ["testing", "debugBuild", "notConfigured", "notInstalled"])
    }
}
