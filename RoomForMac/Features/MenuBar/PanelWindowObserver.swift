import AppKit
import SwiftUI

/// Reports whether the menu-bar panel is on screen. SwiftUI has no API for it (FB11984872),
/// and the panel's content may stay alive between openings, so `onAppear` alone misses them
/// (research §5.3). This view watches its own window instead: becoming key means the panel
/// opened, resigning key means it is closing, and an occlusion change or a close re-reads it.
/// Each change is reported once.
struct PanelWindowObserver: NSViewRepresentable {
    private let onVisibleChange: @MainActor (Bool) -> Void

    init(onVisibleChange: @escaping @MainActor (Bool) -> Void) {
        self.onVisibleChange = onVisibleChange
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onVisibleChange = onVisibleChange
        return view
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onVisibleChange = onVisibleChange
    }

    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.stopObserving()
    }

    /// The AppKit view behind the observer. Its window's notifications arrive through
    /// selector-based observers, which Foundation removes when the view goes away.
    final class ObserverView: NSView {
        var onVisibleChange: (@MainActor (Bool) -> Void)?

        /// Whether a window is on screen, read for the first report and after an occlusion
        /// change. Tests replace it.
        var isOnScreen: @MainActor (NSWindow) -> Bool = { window in
            window.isVisible && window.occlusionState.contains(.visible)
        }

        static let windowNotifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
        ]

        private weak var observedWindow: NSWindow?
        private var lastReported: Bool?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            stopObserving()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                report(false)
                return
            }
            for name in Self.windowNotifications {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowDidNotify(_:)), name: name, object: window
                )
            }
            observedWindow = window
            report(window.isKeyWindow || isOnScreen(window))
        }

        func stopObserving() {
            guard let window = observedWindow else {
                return
            }
            for name in Self.windowNotifications {
                NotificationCenter.default.removeObserver(self, name: name, object: window)
            }
            observedWindow = nil
        }

        /// What one of the window's notifications means for the panel.
        func windowNotified(_ name: Notification.Name) {
            switch name {
            case NSWindow.didBecomeKeyNotification:
                report(true)
            case NSWindow.didResignKeyNotification, NSWindow.willCloseNotification:
                report(false)
            default:
                guard let window else {
                    report(false)
                    return
                }
                report(window.isKeyWindow || isOnScreen(window))
            }
        }

        @objc private func windowDidNotify(_ notification: Notification) {
            windowNotified(notification.name)
        }

        private func report(_ visible: Bool) {
            guard visible != lastReported else {
                return
            }
            lastReported = visible
            onVisibleChange?(visible)
        }
    }
}
