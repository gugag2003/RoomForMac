import Foundation
import Testing

/// The unit tests run inside RoomForMac.app, so `Bundle.main` is the built app.
@Suite("App bundle")
struct AppBundleInfoTests {
    private func info(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    @Test func identity() {
        #expect(Bundle.main.bundleIdentifier == "com.roomformac.app")
        #expect(Bundle.main.bundleURL.lastPathComponent == "RoomForMac.app")
        #expect(info("CFBundleDisplayName") == "RoomForMac")
        #expect(info("LSApplicationCategoryType") == "public.app-category.utilities")
        #expect(info("LSMinimumSystemVersion") == "26.0")
    }

    @Test func urlScheme() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        #expect(types.count == 1)
        #expect(types.first?["CFBundleURLName"] as? String == "com.roomformac.app")
        #expect(types.first?["CFBundleURLSchemes"] as? [String] == ["roomformac"])
    }

    @Test func appleEventsReasonIsVerbatim() {
        #expect(info("NSAppleEventsUsageDescription") == """
            RoomForMac asks Finder for your disk's free space and, if needed, to move apps to the Trash. \
            It asks System Events which apps are running before a cleanup and to remove the login items \
            of apps you uninstall.
            """)
    }

    @Test func folderReasonsForWhenFullDiskAccessIsSkipped() {
        #expect(info("NSDownloadsFolderUsageDescription") == "RoomForMac looks for unfinished downloads it can clean up.")
        #expect(info("NSDesktopFolderUsageDescription") == "RoomForMac measures what fills your Desktop.")
        #expect(info("NSDocumentsFolderUsageDescription") == "RoomForMac measures what fills your Documents folder.")
        #expect(info("NSRemovableVolumesUsageDescription") == "RoomForMac measures what fills your external drives.")
        #expect(info("NSNetworkVolumesUsageDescription") == "RoomForMac measures what fills network drives you choose.")
    }

    @Test func theAppIsNotSandboxed() {
        #expect(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil)
        #expect(!NSHomeDirectory().contains("/Library/Containers/"))
    }
}
