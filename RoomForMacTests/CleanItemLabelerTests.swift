import Foundation
import MoleEngine
import Testing
@testable import RoomForMac

@Suite("Clean item labels", .timeLimit(.minutes(1)))
struct CleanItemLabelerTests {
    private static let apps = ["com.example.alpha": "Alpha", "com.apple.Safari": "Safari"]

    private func label(_ path: String) -> String {
        let item = CleanItem(section: "User essentials", path: path, sizeBytes: 0, sizeKnown: true)
        return CleanItemLabeler.label(for: item, home: "/Users/test/", appName: { Self.apps[$0] })
    }

    @Test(arguments: [
        ("/Users/test/Library/Caches/com.example.alpha", "Alpha"),
        ("/Users/test/Library/Caches/com.apple.Safari/", "Safari"),
        ("/Users/test/Library/Developer/Xcode/DerivedData/Proj-abc", "Xcode build data · Proj"),
        ("/Users/test/Library/Developer/Xcode/DerivedData/My-App-dxqzfhvdzbkfoyewpnhemvbhzjom/Build",
         "Xcode build data · My-App"),
        ("/Users/test/Library/Developer/Xcode/DerivedData/ModuleCache.noindex", "Xcode build data · ModuleCache.noindex"),
        ("/Users/test/Library/Developer/Xcode/DerivedData", "Xcode build data"),
        ("/Users/test/.Trash/old-file.bin", "Trash · old-file.bin"),
        ("/Users/test/.Trash/Old Project/build", "Trash · Old Project"),
        ("/Users/test/.Trash/com.example.alpha", "Trash · Alpha"),
        ("/Users/test/.Trash", "Trash"),
        ("/Users/test/Downloads/iPhone15,2_26.0_Restore.ipsw", "iOS software update"),
        ("/Users/test/Library/iTunes/iPad Software Updates/iPad.IPSW", "iOS software update"),
        ("/var/folders/yf/abc123/C/clang/ModuleCache", "Clang module cache"),
        ("/private/var/folders/yf/abc123/C/clang/ModuleCache", "Clang module cache"),
        ("/Users/test/Library/Logs/DiagnosticReports", "Logs · DiagnosticReports"),
        ("/Users/test/Library/Logs/com.example.alpha/today.log", "Logs · Alpha"),
        ("/Users/test/Library/Logs/com.example.gone", "Logs · com.example.gone"),
        ("/Users/test/Library/Logs", "Logs"),
        ("/Users/test/Library/Caches/Google", "~/Library/Caches/Google"),
        ("/Users/test/Library/Caches/com.example.gone", "~/Library/Caches/com.example.gone"),
        ("/Users/test/Library/Caches/com.example.alpha/sub", "~/Library/Caches/com.example.alpha/sub"),
        ("/Users/test", "~"),
        ("/Users/testing/Library/Logs/x", "/Users/testing/Library/Logs/x"),
        ("/var/folders/yf/abc123/C/other", "/var/folders/yf/abc123/C/other"),
    ])
    func theLabelTable(path: String, expected: String) {
        #expect(label(path) == expected)
    }

    @Test func longPathsAreMiddleTruncatedToSixtyCharacters() {
        let path = "/Users/test/Library/Application Support/Some Vendor/Some Very Long Product Name/Cache/Data/blobs"
        #expect(label(path) == "~/Library/Application Support… Product Name/Cache/Data/blobs")
        #expect(label(path).count == CleanItemLabeler.maximumLength)
        let exact = "/Users/test/" + String(repeating: "x", count: 58)
        #expect(label(exact) == "~/" + String(repeating: "x", count: 58))
    }

    @Test func aBundleIdentifierWithNoAppFallsBackToThePath() {
        let item = CleanItem(section: "App caches", path: "/Users/test/Library/Caches/com.example.alpha", sizeBytes: 0, sizeKnown: true)
        #expect(CleanItemLabeler.label(for: item, home: "/Users/test", appName: { _ in nil })
            == "~/Library/Caches/com.example.alpha")
    }
}
