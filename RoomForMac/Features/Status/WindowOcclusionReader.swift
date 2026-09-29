import AppKit
import SwiftUI

/// Reports whether the window it sits in can be seen: whether the window's
/// `occlusionState` contains `.visible`. A minimised, hidden or fully covered
/// window, or one on another Space, cannot (research §5.3).
///
/// It reports once it is in a window, then on every change, never twice in a row
/// with the same value, and never inside a SwiftUI update. It draws nothing and
/// takes no clicks.
struct WindowOcclusionReader: NSViewRepresentable {
    private let onChange: @MainActor (Bool) -> Void

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    func makeNSView(context: Context) -> WatcherView {
        WatcherView(onChange: onChange)
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
        view.stopWatching()
    }

    /// The AppKit side: it observes `NSWindow.didChangeOcclusionStateNotification`
    /// for the window it is in.
    final class WatcherView: NSView {
        var onChange: @MainActor (Bool) -> Void
        private var observer: (any NSObjectProtocol)?
        private var lastReported: Bool?

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("WatcherView is only made in code")
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard let window else {
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.report()
                }
            }
            // After this update, not inside it: the report changes SwiftUI state.
            Task { [weak self] in
                self?.report()
            }
        }

        /// Stops observing. Moving into a window again starts over, with a fresh report.
        func stopWatching() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            lastReported = nil
        }

        /// Sends the window's visibility, unless it is the value sent last.
        func report() {
            guard let window else {
                return
            }
            let visible = window.occlusionState.contains(.visible)
            guard visible != lastReported else {
                return
            }
            lastReported = visible
            onChange(visible)
        }
    }
}
