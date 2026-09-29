import SwiftUI

/// The Status section (spec §5.4): the health line and one card per part of the Mac,
/// fed by the app's one `StatusMonitor`.
///
/// While the section is on screen it holds the monitor's `.statusSection` demand, so
/// `status-go` runs at the live cadence (Ruling 16). It lets go when the section
/// disappears (another section is picked, or the window closes) and while its window
/// is minimised, hidden, covered or on another Space.
struct StatusView: View {
    private let appModel: AppModel

    @State private var isShown = false
    @State private var isWindowVisible = true

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    var body: some View {
        // The monitor exists whenever this view does: `start()` builds it in the same
        // main-actor turn that makes the engine ready, and the sidebar needs a ready engine.
        let monitor = appModel.statusMonitor
        ScrollView {
            StatusGrid(
                reading: monitor?.latest,
                history: monitor?.history ?? StatusHistory(),
                freeSpace: monitor?.freeSpace,
                failure: monitor?.failure
            )
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background {
            WindowOcclusionReader { visible in
                isWindowVisible = visible
                Self.applyDemand(to: appModel.statusMonitor, shown: isShown, windowVisible: visible)
            }
        }
        .onAppear {
            isShown = true
            Self.applyDemand(to: appModel.statusMonitor, shown: true, windowVisible: isWindowVisible)
        }
        .onDisappear {
            isShown = false
            Self.applyDemand(to: appModel.statusMonitor, shown: false, windowVisible: isWindowVisible)
        }
    }

    /// Whether the section counts as on screen: it has appeared, and its window is at
    /// least partly visible.
    static func isOnScreen(shown: Bool, windowVisible: Bool) -> Bool {
        shown && windowVisible
    }

    /// Sets or clears the `.statusSection` demand to match.
    static func applyDemand(to monitor: StatusMonitor?, shown: Bool, windowVisible: Bool) {
        monitor?.setDemand(.statusSection, isOnScreen(shown: shown, windowVisible: windowVisible))
    }
}

/// The Status section's content as a value view: "Reading your Mac…" before the first
/// reading, the failure note while the monitor retries, then the health line and the
/// cards. The battery card is left out on a Mac without a battery.
struct StatusGrid: View {
    private let reading: StatusReading?
    private let history: StatusHistory
    private let freeSpace: FreeSpace?
    private let failure: StatusMonitor.Failure?

    init(reading: StatusReading?, history: StatusHistory, freeSpace: FreeSpace?, failure: StatusMonitor.Failure?) {
        self.reading = reading
        self.history = history
        self.freeSpace = freeSpace
        self.failure = failure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let failure {
                StatusFailureCard(failure: failure)
            }
            if let reading {
                HealthLine(summary: reading.health)
                StatusCardLayout {
                    ForEach(Self.kinds(for: reading), id: \.self) { kind in
                        StatusCard(kind: kind, reading: reading, history: history, freeSpace: freeSpace)
                    }
                }
            } else if failure == nil {
                StatusWaitingView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The cards `reading` has values for, in `StatusCardKind` order.
    static func kinds(for reading: StatusReading) -> [StatusCardKind] {
        StatusCardKind.allCases.filter { kind in
            switch kind {
            case .cpu: reading.cpu != nil
            case .gpu: reading.gpu != nil
            case .memory: reading.memory != nil
            case .disk: reading.disk != nil
            case .network: reading.network != nil
            case .battery: reading.battery != nil
            }
        }
    }
}

/// The cards in equal columns, as many as fit at `minimumColumnWidth` up to
/// `maximumColumnCount`, and every card in a row as tall as the row. Six cards at
/// most, so nothing is lazy.
struct StatusCardLayout: Layout {
    var minimumColumnWidth: CGFloat = 250
    var maximumColumnCount = 3
    var spacing: CGFloat = 16

    /// How many columns fit in `width`: at least one, at most `maximumColumnCount`.
    func columnCount(for width: CGFloat) -> Int {
        guard width.isFinite, width > minimumColumnWidth else {
            return 1
        }
        let fitting = Int(((width + spacing) / (minimumColumnWidth + spacing)).rounded(.down))
        return min(max(1, fitting), max(1, maximumColumnCount))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? minimumColumnWidth * CGFloat(maximumColumnCount) + spacing * CGFloat(maximumColumnCount - 1)
        let heights = rowHeights(subviews: subviews, width: width)
        let height = heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columnCount(for: bounds.width)
        let width = columnWidth(in: bounds.width, columns: columns)
        var y = bounds.minY
        for (row, height) in rowHeights(subviews: subviews, width: bounds.width).enumerated() {
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else {
                    break
                }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (width + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: height)
                )
            }
            y += height + spacing
        }
    }

    private func columnWidth(in width: CGFloat, columns: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    /// Each row's height: its tallest card at the column width.
    private func rowHeights(subviews: Subviews, width: CGFloat) -> [CGFloat] {
        let columns = columnCount(for: width)
        let proposal = ProposedViewSize(width: columnWidth(in: width, columns: columns), height: nil)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)]
                .map { $0.sizeThatFits(proposal).height }
                .max() ?? 0
        }
    }
}

/// "Reading your Mac…" until the first snapshot, which arrives about half a second
/// after the monitor resumes `status-go` (research §5.2).
private struct StatusWaitingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassCard(cornerRadius: 20, padding: 24) {
            VStack(spacing: 12) {
                Image(systemName: SidebarSection.status.systemImage)
                    .font(.system(size: 48))
                    .foregroundStyle(Palette.moss)
                    .symbolEffect(.pulse, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                Text("Reading your Mac…")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.statusWaiting)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}

/// "Status paused: …" while the monitor retries the engine along its backoff. The
/// cards, when there are any, keep the last reading underneath.
private struct StatusFailureCard: View {
    let failure: StatusMonitor.Failure

    var body: some View {
        GlassCard(cornerRadius: 18, padding: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(Palette.grass)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status paused: \(message)")
                        .font(.headline)
                        .foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("RoomForMac tries again in a moment.")
                        .font(.callout)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.statusFailure)
    }

    private var message: String {
        switch failure {
        case .engineStopped(let presentation):
            presentation.message
        }
    }
}
