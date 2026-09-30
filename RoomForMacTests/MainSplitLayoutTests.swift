import AppKit
import SwiftUI
import Testing
@testable import RoomForMac

/// The main window's sidebar stays on screen whatever the detail column shows.
///
/// NavigationSplitView measures the detail's minimum height at a narrow width. A multiline
/// text fixed to its ideal height (the Smart Clean hero, a permission card) wraps there into
/// thousands of points, and that minimum became the window content's: the split view grew
/// taller than the window and the sidebar list was laid out above it, so the sidebar looked
/// empty until a screen without such text (the scan ring) appeared.
@MainActor
@Suite("Main split layout")
struct MainSplitLayoutTests {
    /// The sidebar of `MainSplitView`, over `detail`.
    private struct Harness<Detail: View>: View {
        @State private var selection: SidebarSection = .smartClean
        let detail: Detail

        var body: some View {
            NavigationSplitView {
                List(SidebarSection.allCases, selection: $selection) { section in
                    Label(section.title, systemImage: section.systemImage).tag(section)
                }
            } detail: {
                detail
            }
            .frame(minWidth: 800, minHeight: 540)
        }
    }

    private static let windowSize = NSSize(width: 1100, height: 720)

    private func outlines(in view: NSView) -> [NSOutlineView] {
        (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap { outlines(in: $0) }
    }

    /// The sidebar's frame in a laid-out window of `windowSize`, and how tall the content asks to be.
    private func layOut(_ detail: some View) throws -> (sidebar: NSRect, fittingHeight: CGFloat) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Harness(detail: detail))
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        let sidebar = try #require(outlines(in: host).first)
        return (sidebar.convert(sidebar.bounds, to: nil), host.fittingSize.height)
    }

    private var hero: some View {
        SmartCleanHero(fullDiskAccess: .denied, blockedBy: nil, note: .scanStopped, scan: {}, allowFullDiskAccess: {})
    }

    @Test func theIdleSmartCleanHeroKeepsTheSidebarInTheWindow() throws {
        let laidOut = try layOut(hero.detailColumnFrame())
        #expect(laidOut.fittingHeight <= Self.windowSize.height)
        #expect(laidOut.sidebar.minY >= 0)
        #expect(laidOut.sidebar.maxY <= Self.windowSize.height)
    }

    @Test func aPermissionCardKeepsTheSidebarInTheWindow() throws {
        let card = PermissionCard(
            id: .fullDiskAccess, state: .denied, title: "Full Disk Access",
            reason: "Some folders can't be measured or cleaned without it.",
            actionTitle: "Open Settings", action: {}
        )
        let laidOut = try layOut(card.frame(maxWidth: 460).detailColumnFrame())
        #expect(laidOut.fittingHeight <= Self.windowSize.height)
        #expect(laidOut.sidebar.minY >= 0)
    }
}
