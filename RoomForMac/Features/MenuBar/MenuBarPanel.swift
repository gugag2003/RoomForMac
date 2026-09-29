import AppKit
import SwiftUI

/// The menu-bar extra's window (spec §5.5): CPU, memory and disk gauges, the free space, the
/// health headline, **Quick Scan**, **Open RoomForMac** and **Quit**.
///
/// While it is on screen it asks the Status monitor for live readings (`.menuBarPanel`,
/// Ruling 16) and reads the free space again; closing it clears that demand.
struct MenuBarPanel: View {
    private let model: AppModel
    private let router: WindowRouter

    /// What was last told to the monitor, so `onAppear`, `onDisappear` and the window observer
    /// can all report without repeating themselves.
    @State private var isVisible = false

    init(model: AppModel, router: WindowRouter) {
        self.model = model
        self.router = router
    }

    var body: some View {
        MenuBarPanelContent(
            status: Self.status(of: model),
            canQuickScan: model.smartClean != nil,
            actions: MenuBarPanelContent.Actions(
                quickScan: { Self.quickScan(model: model, router: router) },
                openApp: { router.showMain() },
                quit: { NSApp.terminate(nil) }
            )
        )
        .background {
            PanelWindowObserver { visible in
                setVisible(visible)
            }
            .frame(width: 0, height: 0)
        }
        .onAppear {
            setVisible(true)
        }
        .onDisappear {
            setVisible(false)
        }
        .onChange(of: model.statusMonitor.map { ObjectIdentifier($0) }) {
            // A monitor made while the panel was open (the engine became ready) hears about it.
            applyVisibility()
        }
    }

    /// Starting while the engine check runs, or before the monitor exists; the reinstall
    /// notice for a broken engine; otherwise the monitor's latest values.
    static func status(of model: AppModel) -> MenuBarPanelContent.Status {
        switch model.engine {
        case .checking:
            return .starting
        case .broken:
            return .needsReinstall
        case .ready:
            guard let monitor = model.statusMonitor else {
                return .starting
            }
            return .ready(MenuBarGauges.make(reading: monitor.latest, freeSpace: monitor.freeSpace))
        }
    }

    /// **Quick Scan**: asks Smart Clean for a scan and shows it. While Smart Clean is busy
    /// (scanning, rechecking or cleaning) it only shows the window.
    static func quickScan(model: AppModel, router: WindowRouter) {
        if model.smartClean?.isBusy == true {
            router.showMain(section: .smartClean)
        } else {
            model.requestQuickScan()
            router.showMain(section: .smartClean, quickScan: true)
        }
    }

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else {
            return
        }
        isVisible = visible
        applyVisibility()
    }

    private func applyVisibility() {
        guard let monitor = model.statusMonitor else {
            return
        }
        monitor.setDemand(.menuBarPanel, isVisible)
        if isVisible {
            monitor.refreshFreeSpace()
        }
    }
}

/// The panel's content as values, so it renders in tests without a model.
struct MenuBarPanelContent: View {
    enum Status: Equatable {
        /// The engine check runs, or the Status monitor does not exist yet.
        case starting
        /// The engine is broken; the main window explains it.
        case needsReinstall
        case ready(MenuBarGauges)
    }

    struct Actions {
        var quickScan: @MainActor () -> Void
        var openApp: @MainActor () -> Void
        var quit: @MainActor () -> Void
    }

    static let width: CGFloat = 300

    private let status: Status
    private let canQuickScan: Bool
    private let actions: Actions

    init(status: Status, canQuickScan: Bool, actions: Actions) {
        self.status = status
        self.canQuickScan = canQuickScan
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch status {
            case .starting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting…")
                        .foregroundStyle(Palette.textSecondary)
                }
            case .needsReinstall:
                Label {
                    Text("RoomForMac needs to be reinstalled")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(Palette.text)
            case .ready(let gauges):
                HStack(alignment: .top, spacing: 12) {
                    MenuBarGaugeView(kind: .cpu, percent: gauges.cpu)
                    MenuBarGaugeView(kind: .memory, percent: gauges.memory)
                    MenuBarGaugeView(kind: .disk, percent: gauges.diskUsed)
                }
                freeSpace(gauges.freeBytes)
            }
            buttons
        }
        .padding(16)
        .frame(width: Self.width)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.menuBarPanel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("RoomForMac")
                .font(.headline)
                .foregroundStyle(Palette.text)
            if case .ready(let gauges) = status, let headline = gauges.headline {
                Text(headline.title)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func freeSpace(_ bytes: Int64?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Free space")
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Text(verbatim: bytes.map { ByteText.string($0) } ?? "—")
                .font(Typography.numeral)
                .foregroundStyle(Palette.grass)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.menuBarFreeSpace)
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassButton(.primary, action: actions.quickScan) {
                Text("Quick Scan")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!canQuickScan)
            .accessibilityIdentifier(AccessibilityID.menuBarQuickScan)
            GlassButton(.secondary, action: actions.openApp) {
                Text("Open RoomForMac")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier(AccessibilityID.menuBarOpenApp)
            Divider()
            Button(action: actions.quit) {
                Text("Quit RoomForMac")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Palette.textSecondary)
            .accessibilityIdentifier(AccessibilityID.menuBarQuit)
        }
    }
}

/// One circular gauge with its title under it. VoiceOver reads it as one element: the title,
/// then the percentage or "No reading yet".
struct MenuBarGaugeView: View {
    private let kind: StatusCardKind
    private let percent: Double?

    init(kind: StatusCardKind, percent: Double?) {
        self.kind = kind
        self.percent = percent
    }

    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: (percent ?? 0) / 100) {
                Text(kind.title)
            } currentValueLabel: {
                Text(verbatim: valueText)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(Palette.moss)
            Text(kind.title)
                .font(Typography.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(kind.title))
        .accessibilityValue(percent == nil ? Text("No reading yet") : Text(verbatim: valueText))
        .accessibilityIdentifier(AccessibilityID.menuBarGauge(kind))
    }

    /// "37%", or "—" before the first reading.
    private var valueText: String {
        guard let percent else {
            return "—"
        }
        return (percent / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}
