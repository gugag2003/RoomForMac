import AppKit
import Observation
import SwiftUI

/// Requests to show the main window from code that cannot call SwiftUI's `openWindow`: the app
/// delegate (a launch, a Dock click, a link), the menu-bar panel and, later, notifications.
/// A `WindowRouterBridge` on screen carries each request out.
@MainActor
@Observable
final class WindowRouter {
    struct Request: Sendable, Equatable {
        /// The sidebar section to show; nil keeps the current one.
        var section: SidebarSection?
        /// Whether Smart Clean should start a scan (`AppModel.requestQuickScan()`).
        var quickScan: Bool
    }

    /// The identifier of the main `Window` scene.
    static let mainWindowID = "main"

    /// The request no bridge has taken yet.
    private(set) var pending: Request?

    /// Opens the main window or brings it forward. The first bridge on screen sets it from
    /// SwiftUI's `openWindow`, so a request made while no bridge is on screen (the extra taken
    /// out of the menu bar and the window closed) can still open the window. Nil until then.
    @ObservationIgnored var openMainWindow: (@MainActor () -> Void)?

    init() {}

    /// Asks for the main window. A request that no bridge has taken yet absorbs this one: a
    /// later section wins, and a Quick Scan asked for once stays asked for.
    func showMain(section: SidebarSection? = nil, quickScan: Bool = false) {
        var request = pending ?? Request(section: nil, quickScan: false)
        if let section {
            request.section = section
        }
        request.quickScan = request.quickScan || quickScan
        pending = request
        openMainWindow?()
    }

    /// The pending request, once: a second call returns nil until the next `showMain`.
    func take() -> Request? {
        guard let request = pending else {
            return nil
        }
        pending = nil
        return request
    }
}

/// Carries out `WindowRouter` requests from a view that is on screen: it opens the main window,
/// activates the app, then applies the section and the Quick Scan to the model. The menu-bar
/// label carries one, because it exists while the window is closed (research §9, finding 8);
/// the window's content carries another, for a request made while the extra is off.
struct WindowRouterBridge: ViewModifier {
    private let router: WindowRouter
    private let model: AppModel

    @Environment(\.openWindow) private var openWindow

    init(router: WindowRouter, model: AppModel) {
        self.router = router
        self.model = model
    }

    func body(content: Content) -> some View {
        content
            .onAppear {
                let openWindow = openWindow
                router.openMainWindow = { openWindow(id: WindowRouter.mainWindowID) }
                deliver()
            }
            .onChange(of: router.pending) {
                deliver()
            }
    }

    private func deliver() {
        guard let request = router.take() else {
            return
        }
        openWindow(id: WindowRouter.mainWindowID)
        NSApp.activate()
        Self.apply(request, to: model)
    }

    /// Selects the requested section, then asks for the Quick Scan, which shows Smart Clean.
    static func apply(_ request: WindowRouter.Request, to model: AppModel) {
        if let section = request.section {
            model.selection = section
        }
        if request.quickScan {
            model.requestQuickScan()
        }
    }
}
