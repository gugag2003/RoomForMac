import Foundation
import MoleEngine

/// Plain-language text for any error: a title and message for the card, and technical
/// `details` for "Show details" and "Copy diagnostics".
struct ErrorPresentation: Sendable, Equatable {
    var title: String
    var message: String
    var details: String

    init(_ error: any Error) {
        switch error {
        case let problem as EngineProblem:
            self = Self.presenting(problem)
        case let engineError as EngineError:
            self = Self.presenting(engineError)
        case is CancellationError:
            self = Self.presenting(EngineError.cancelled)
        case let decodingError as DecodingError:
            // Checked before CocoaError: a DecodingError also bridges to NSCocoaErrorDomain.
            self = Self.presenting(decodingError)
        case let cocoaError as CocoaError where cocoaError.isFileError:
            self = Self.presentingFileError(cocoaError)
        default:
            self = Self.presentingUnknown(error)
        }
    }

    private init(title: String, message: String, details: String) {
        self.title = title
        self.message = message
        self.details = details
    }

    /// A report to paste into a bug report. It adds no file paths of its own: only `details`
    /// can carry one.
    func diagnostics(appVersion: String, osVersion: String) -> String {
        [
            String(localized: "RoomForMac diagnostics"),
            String(localized: "Title: \(title)"),
            String(localized: "Message: \(message)"),
            String(localized: "Details:"),
            details,
            String(localized: "App \(appVersion)"),
            String(localized: "macOS \(osVersion)"),
            String(localized: "Expected engine: \(EngineFingerprint.expected.summary)"),
        ].joined(separator: "\n")
    }

    /// "0.1.0 (1)" from `CFBundleShortVersionString` and `CFBundleVersion`.
    static func appVersion(info: [String: Any]?) -> String {
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }

    /// "27.0.1".
    static func osVersion(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    // MARK: - Mappings

    private static func presenting(_ problem: EngineProblem) -> ErrorPresentation {
        let title = String(localized: "RoomForMac needs to be reinstalled")
        switch problem {
        case .installationInvalid(let reason):
            return ErrorPresentation(
                title: title,
                message: String(localized: "Some files RoomForMac needs are missing or damaged."),
                details: reason
            )
        case .versionMismatch(let expected, let found):
            return ErrorPresentation(
                title: title,
                message: String(localized: "The engine inside RoomForMac doesn't match this version of the app."),
                details: lines(
                    String(localized: "Expected: \(expected.summary)"),
                    String(localized: "Found: \(found.summary)")
                )
            )
        case .selfTestFailed(let tool, let detail):
            return ErrorPresentation(
                title: title,
                message: String(localized: "Part of RoomForMac's engine couldn't run. macOS may have blocked it, or the app is damaged."),
                details: lines(tool, detail)
            )
        }
    }

    private static func presenting(_ error: EngineError) -> ErrorPresentation {
        switch error {
        case .installationInvalid(let reason):
            return presenting(EngineProblem.installationInvalid(reason))
        case .launchFailed(let executable, let reason):
            let name = URL(fileURLWithPath: executable).lastPathComponent
            return ErrorPresentation(
                title: String(localized: "The engine couldn't start"),
                message: String(localized: "RoomForMac couldn't start \(name)."),
                details: lines(executable, reason)
            )
        case .nonZeroExit(let code, let stderrTail):
            return ErrorPresentation(
                title: String(localized: "The engine ran into a problem"),
                message: String(localized: "It stopped with error code \(Int(code))."),
                details: lines(String(localized: "Exit code \(Int(code))"), stderrTail)
            )
        case .terminatedBySignal(let signal, let stderrTail):
            return ErrorPresentation(
                title: String(localized: "The engine stopped unexpectedly"),
                message: String(localized: "macOS ended it before it finished."),
                details: lines(String(localized: "Signal \(Int(signal))"), stderrTail)
            )
        case .timedOut:
            return ErrorPresentation(
                title: String(localized: "The engine took too long"),
                message: String(localized: "RoomForMac stopped it after waiting too long. Try again."),
                details: String(describing: error)
            )
        case .cancelled:
            return ErrorPresentation(
                title: String(localized: "Stopped"),
                message: String(localized: "The engine was stopped before it finished."),
                details: String(describing: error)
            )
        case .malformedOutput(let reason):
            return ErrorPresentation(
                title: String(localized: "The engine returned something unexpected"),
                message: String(localized: "RoomForMac couldn't read the engine's answer."),
                details: reason
            )
        }
    }

    private static func presenting(_ error: DecodingError) -> ErrorPresentation {
        let context: DecodingError.Context
        switch error {
        case .typeMismatch(_, let found), .valueNotFound(_, let found), .keyNotFound(_, let found), .dataCorrupted(let found):
            context = found
        @unknown default:
            return presentingUnknown(error)
        }
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return ErrorPresentation(
            title: String(localized: "The engine returned something unexpected"),
            message: String(localized: "RoomForMac couldn't read the engine's answer."),
            details: path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        )
    }

    private static func presentingFileError(_ error: CocoaError) -> ErrorPresentation {
        let message = if let path = error.filePath ?? error.url?.path {
            String(localized: "RoomForMac couldn't use the file at \(path).")
        } else {
            String(localized: "RoomForMac couldn't use a file it needs.")
        }
        return ErrorPresentation(
            title: String(localized: "RoomForMac couldn't use a file"),
            message: message,
            details: lines("\(CocoaError.errorDomain) \(error.errorCode)", error.localizedDescription)
        )
    }

    private static func presentingUnknown(_ error: any Error) -> ErrorPresentation {
        let nsError = error as NSError
        let message = (error as? LocalizedError)?.errorDescription
            ?? String(localized: "RoomForMac ran into an unexpected problem.")
        return ErrorPresentation(
            title: String(localized: "Something went wrong"),
            message: message,
            details: lines("\(nsError.domain) \(nsError.code)", String(describing: error))
        )
    }

    /// Joins non-empty pieces of technical text, one per line, without trailing whitespace.
    private static func lines(_ parts: String...) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
