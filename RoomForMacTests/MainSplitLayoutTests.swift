import AppKit
import SwiftUI
import Testing
@testable import RoomForMac

/// The main window's sidebar stays on screen whatever the detail column shows.
///
/// A multiline text fixed to its ideal height (the Smart Clean hero, a permission card) wraps
/// into thousands of points when it is measured at a narrow width. When that minimum became the
/// window content's, the content grew taller than the window and the sidebar was laid out above
/// it, so the sidebar looked empty until a screen without such text (the scan ring) appeared.
@MainActor
@Suite("Main split layout")
struct MainSplitLayoutTests {
    /// `MainSplitView`'s layout without its model: the sidebar beside `detail`.
    private struct Harness<Detail: View>: View {
        @State private var selection: SidebarSection = .smartClean
        let detail: Detail

        var body: some View {
            SidebarLayout(selection: $selection) { detail }
                .frame(minWidth: 800, minHeight: 540)
        }
    }

    private static let windowSize = NSSize(width: 1100, height: 720)
    /// The main window's smallest content size (`RootView`).
    private static let minimumWindowSize = NSSize(width: 800, height: 540)

    /// How tall `view` asks to be, laid out in a window of `windowSize`. When it asks for more than
    /// the window, the content overflows the window and the sidebar is laid out above it.
    private func fittingHeight(_ view: some View) -> CGFloat {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private var hero: some View {
        SmartCleanHero(fullDiskAccess: .denied, blockedBy: nil, note: .scanStopped, scan: {}, allowFullDiskAccess: {})
    }

    @Test func theIdleSmartCleanHeroKeepsTheSidebarInTheWindow() {
        #expect(fittingHeight(Harness(detail: hero)) <= Self.windowSize.height)
    }

    @Test func aPermissionCardKeepsTheSidebarInTheWindow() {
        let card = PermissionCard(
            id: .fullDiskAccess, state: .denied, title: "Full Disk Access",
            reason: "Some folders can't be measured or cleaned without it.",
            actionTitle: "Open Settings", action: {}
        )
        #expect(fittingHeight(Harness(detail: card.frame(maxWidth: 460))) <= Self.windowSize.height)
    }

    /// The rows and the Settings footer fit the smallest window, at the sidebar's fixed width.
    @Test func theSidebarFitsTheSmallestWindow() {
        let host = NSHostingView(rootView: Sidebar(selection: .constant(.smartClean)))
        #expect(host.fittingSize.width == Sidebar.width)
        #expect(host.fittingSize.height <= Self.minimumWindowSize.height)
    }
}
