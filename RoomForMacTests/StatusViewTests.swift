import AppKit
import Foundation
import MoleEngine
import SwiftUI
import Testing
@testable import RoomForMac

/// The Status UI: what each card shows and says to VoiceOver, the sparkline's scale,
/// the grid in every state, the window watcher, and the section's demand on the
/// monitor. Render tests compare pixels with `RenderedPixels`, as Plan 2's do.
@MainActor
@Suite("Status view", .timeLimit(.minutes(1)))
struct StatusViewTests {
    // MARK: - Identifiers

    @Test func accessibilityIdentifiers() {
        #expect(StatusCardKind.allCases.map(AccessibilityID.statusCard) == [
            "status.card.cpu", "status.card.gpu", "status.card.memory",
            "status.card.disk", "status.card.network", "status.card.battery",
        ])
        #expect(AccessibilityID.statusHealth == "status.health")
        #expect(AccessibilityID.statusWaiting == "status.waiting")
        #expect(AccessibilityID.statusFailure == "status.failure")
    }

    // MARK: - Card content

    /// The whole VoiceOver label of one card, in `en_US`: title, figure, details,
    /// then the chart's range and the two minutes its 60 samples span.
    @Test func theCPUSummaryNamesItsValuesAndTheTimeSpan() throws {
        var reading = try Self.fullReading()
        reading.cpu = StatusReading.CPU(usage: 42, cores: 8, load1: 2.5)
        let history = Self.history(count: 60) { index in index == 0 ? 12 : index == 30 ? 95 : 40 }
        let content = try #require(StatusCardContent.make(
            kind: .cpu, reading: reading, history: history, freeSpace: nil, locale: Self.english
        ))
        #expect(content.figure == "42%")
        #expect(content.details == ["8 cores", "Load 2.50"])
        #expect(content.domain == 0...100)
        #expect(content.accessibilitySummary(title: "CPU", locale: Self.english)
            == "CPU, 42%, 8 cores, Load 2.50, 12% to 95% over the last 2 minutes")
    }

    @Test(arguments: StatusCardKind.allCases)
    func everySummaryStartsWithTheTitleAndEndsWithTheTimeSpan(kind: StatusCardKind) throws {
        let content = try #require(StatusCardContent.make(
            kind: kind, reading: try Self.fullReading(), history: Self.history(count: 60, value: Self.wave),
            freeSpace: StatusFixtures.freeSpace, locale: Self.english
        ))
        let summary = content.accessibilitySummary(title: "Title", locale: Self.english)
        #expect(summary.hasPrefix("Title, "))
        #expect(summary.hasSuffix(" over the last 2 minutes"))
        #expect(content.points.count == 60)
    }

    @Test func aGPUWithoutUsageSaysSo() throws {
        var reading = try Self.fullReading()
        reading.gpu?.usage = nil
        let content = try #require(StatusCardContent.make(
            kind: .gpu, reading: reading, history: StatusHistory(), freeSpace: nil, locale: Self.english
        ))
        #expect(content.figure == nil)
        #expect(content.spokenFigure == "Usage unavailable")
        #expect(content.historyPhrase == nil)
    }

    /// The disk's figure is the app's free space, which counts purgeable space like
    /// Finder; its chart is reads and writes, so the chart gets a caption.
    @Test func theDiskCardShowsTheAppsFreeSpaceAndWarnsOnSMART() throws {
        var reading = try Self.fullReading()
        let content = try #require(StatusCardContent.make(
            kind: .disk, reading: reading, history: StatusHistory(), freeSpace: StatusFixtures.freeSpace, locale: Self.english
        ))
        #expect(content.figure == ByteText.string(StatusFixtures.freeSpace.importantAvailable))
        #expect(content.figureIsSize)
        #expect(content.details == ["98% used"])
        #expect(content.chartCaption == "Reads and writes")
        #expect(content.domain == nil)
        #expect(content.chip == nil)

        reading.disk?.smartFailing = true
        let failing = try #require(StatusCardContent.make(
            kind: .disk, reading: reading, history: StatusHistory(), freeSpace: StatusFixtures.freeSpace, locale: Self.english
        ))
        #expect(failing.chip == StatusChip.Model(text: "Disk may be failing", tone: .alert))
    }

    /// Ten samples sit at x 50…59: the newest is always at the right edge.
    @Test func theSparklineKeepsTheNewestSampleOnTheRight() throws {
        let content = try #require(StatusCardContent.make(
            kind: .cpu, reading: try Self.fullReading(), history: Self.history(count: 10) { _ in 50 },
            freeSpace: nil, locale: Self.english
        ))
        #expect(content.points.map(\.index) == Array(50...59))
    }

    /// The String Catalog's plural variations: one core, and a new battery's one cycle.
    @Test func oneCoreAndOneCycleAreSingular() throws {
        var reading = try Self.fullReading()
        reading.cpu = StatusReading.CPU(usage: 5, cores: 1, load1: nil)
        reading.battery?.cycleCount = 1
        let cpu = try #require(StatusCardContent.make(
            kind: .cpu, reading: reading, history: StatusHistory(), freeSpace: nil, locale: Self.english
        ))
        let battery = try #require(StatusCardContent.make(
            kind: .battery, reading: reading, history: StatusHistory(), freeSpace: nil, locale: Self.english
        ))
        #expect(cpu.details == ["1 core"])
        #expect(battery.details.contains("1 cycle"))
    }

    @Test func batteryStatusIsCopyOrData() {
        #expect(StatusCardContent.batteryStatus("charged") == "Charged")
        #expect(StatusCardContent.batteryStatus("charging") == "Charging")
        #expect(StatusCardContent.batteryStatus("discharging") == "On battery")
        #expect(StatusCardContent.batteryStatus("finishing") == "Finishing charge")
        #expect(StatusCardContent.batteryStatus("AC") == "Not charging")
        #expect(StatusCardContent.batteryStatus("Unknown") == nil)
        #expect(StatusCardContent.batteryStatus("") == nil)
        #expect(StatusCardContent.batteryStatus("draining fast") == "draining fast")
    }

    @Test func pressureAndHealthChipsCarryWordsAndTones() {
        #expect(StatusCardContent.pressureChip(.unknown) == nil)
        #expect(StatusCardContent.pressureChip(.normal) == StatusChip.Model(text: "Pressure: normal", tone: .calm))
        #expect(StatusCardContent.pressureChip(.warning) == StatusChip.Model(text: "Pressure: high", tone: .caution))
        #expect(StatusCardContent.pressureChip(.critical) == StatusChip.Model(text: "Pressure: critical", tone: .alert))
        #expect(HealthLine.chip(for: .excellent) == StatusChip.Model(text: "Excellent", tone: .calm))
        #expect(HealthLine.chip(for: .good) == StatusChip.Model(text: "Good", tone: .calm))
        #expect(HealthLine.chip(for: .fair) == StatusChip.Model(text: "Fair", tone: .caution))
        #expect(HealthLine.chip(for: .needsAttention) == StatusChip.Model(text: "Needs attention", tone: .alert))
    }

    @Test func anAutomaticScaleStartsAtZeroWithAFloorOfOne() {
        let idle = [SeriesPoint(index: 0, value: 0.2), SeriesPoint(index: 1, value: 0.4)]
        let busy = [SeriesPoint(index: 0, value: 3), SeriesPoint(index: 1, value: 12.5)]
        #expect(Sparkline.yDomain(points: idle, domain: nil) == 0...1)
        #expect(Sparkline.yDomain(points: busy, domain: nil) == 0...12.5)
        #expect(Sparkline.yDomain(points: [], domain: nil) == 0...1)
        #expect(Sparkline.yDomain(points: busy, domain: 0...100) == 0...100)
        #expect(Sparkline.clamped(140, to: 0...100) == 100)
        #expect(Sparkline.clamped(-3, to: 0...100) == 0)
        #expect(Sparkline.clamped(.nan, to: 0...100) == 0)
    }

    // MARK: - Grid

    @Test func aMacWithoutABatteryGetsNoBatteryCard() throws {
        let reading = try Self.fullReading()
        #expect(StatusGrid.kinds(for: reading) == StatusCardKind.allCases)
        var desktop = reading
        desktop.battery = nil
        #expect(StatusGrid.kinds(for: desktop) == [.cpu, .gpu, .memory, .disk, .network])
    }

    @Test func theGridFitsAsManyColumnsAsTheWidthAllows() {
        let layout = StatusCardLayout()
        #expect(layout.columnCount(for: 2000) == 3)
        #expect(layout.columnCount(for: 900) == 3)
        #expect(layout.columnCount(for: 560) == 2)
        #expect(layout.columnCount(for: 516) == 2)
        #expect(layout.columnCount(for: 515) == 1)
        #expect(layout.columnCount(for: 0) == 1)
    }

    // MARK: - Rendering

    @Test(arguments: [ColorScheme.light, .dark])
    func theGridDrawsEveryCard(scheme: ColorScheme) throws {
        let reading = try Self.fullReading()
        let grid = try Self.render(Self.grid(reading, history: Self.history(count: 60, value: Self.wave)), in: scheme)
        let drawn = grid.differingPixels(from: Self.transparent(Self.gridSize))
        #expect(drawn >= Self.minimumDifference, "only \(drawn) pixels differ from an empty frame")
    }

    @Test func theGridFollowsTheColorScheme() throws {
        let view = Self.grid(try Self.fullReading(), history: Self.history(count: 60, value: Self.wave))
        let difference = try Self.render(view, in: .light).differingPixels(from: Self.render(view, in: .dark))
        #expect(difference >= Self.minimumDifference, "only \(difference) pixels differ between light and dark")
    }

    /// A desktop Mac loses the battery card; a Mac whose GPU reports no usage shows
    /// "Usage unavailable" and an empty chart. Both draw differently from the full grid.
    @Test func aMissingBatteryOrGPUUsageChangesTheGrid() throws {
        let reading = try Self.fullReading()
        let full = try Self.render(Self.grid(reading, history: Self.history(count: 60, value: Self.wave)))

        var desktop = reading
        desktop.battery = nil
        let withoutBattery = try Self.render(Self.grid(desktop, history: Self.history(count: 60, value: Self.wave)))
        let batteryDifference = withoutBattery.differingPixels(from: full)
        #expect(batteryDifference >= Self.minimumDifference, "only \(batteryDifference) pixels differ without a battery")

        var noUsage = reading
        noUsage.gpu?.usage = nil
        let noGPUHistory = Self.history(count: 60, gpu: false, value: Self.wave)
        let withoutUsage = try Self.render(Self.grid(noUsage, history: noGPUHistory))
        let gpuDifference = withoutUsage.differingPixels(from: full)
        #expect(gpuDifference >= Self.minimumDifference, "only \(gpuDifference) pixels differ without GPU usage")
    }

    /// Before the first enriched snapshot the reading has no health, and the line is absent.
    @Test func theHealthLineWaitsForAnEnrichedReading() throws {
        let reading = try Self.fullReading()
        #expect(reading.health != nil)
        var early = reading
        early.health = nil
        let history = Self.history(count: 60, value: Self.wave)
        let difference = try Self.render(Self.grid(early, history: history))
            .differingPixels(from: Self.render(Self.grid(reading, history: history)))
        #expect(difference >= Self.minimumDifference, "only \(difference) pixels differ without the health line")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func theWaitingAndFailureStatesDraw(scheme: ColorScheme) throws {
        let empty = Self.transparent(Self.gridSize)
        let waiting = try Self.render(Self.grid(nil), in: scheme)
        let failed = try Self.render(Self.grid(nil, failure: Self.failure), in: scheme)
        let waitingDrawn = waiting.differingPixels(from: empty)
        let failedDrawn = failed.differingPixels(from: empty)
        let apart = failed.differingPixels(from: waiting)
        #expect(waitingDrawn >= Self.minimumDifference, "waiting: only \(waitingDrawn) pixels differ from an empty frame")
        #expect(failedDrawn >= Self.minimumDifference, "failure: only \(failedDrawn) pixels differ from an empty frame")
        #expect(apart >= Self.minimumDifference, "only \(apart) pixels differ between waiting and failure")
    }

    @Test func theWaitingAndFailureStatesFollowTheColorScheme() throws {
        for view in [Self.grid(nil), Self.grid(nil, failure: Self.failure)] {
            let difference = try Self.render(view, in: .light).differingPixels(from: Self.render(view, in: .dark))
            #expect(difference >= Self.minimumDifference, "only \(difference) pixels differ between light and dark")
        }
    }

    /// One sample is a dot; sixty fill an area. Both differ from an empty frame and
    /// from each other.
    @Test func aSparklineDrawsOneAndSixtyPoints() throws {
        let one = try Self.render(
            Sparkline(points: [SeriesPoint(index: 30, value: 50)], domain: 0...100), size: Self.sparklineSize
        )
        let sixty = try Self.render(
            Sparkline(points: (0..<60).map { SeriesPoint(index: $0, value: Self.wave($0)) }, domain: 0...100),
            size: Self.sparklineSize
        )
        let empty = Self.transparent(Self.sparklineSize)
        let dot = one.differingPixels(from: empty)
        let area = sixty.differingPixels(from: empty)
        let apart = sixty.differingPixels(from: one)
        #expect(dot >= 12, "the single sample drew only \(dot) pixels")
        #expect(area >= Self.minimumDifference, "sixty samples drew only \(area) pixels")
        #expect(apart >= Self.minimumDifference, "only \(apart) pixels differ between one and sixty samples")
    }

    // MARK: - On screen

    /// The watcher reports its window's state once it is in the window. This window
    /// is never ordered in, so whatever AppKit says about it is the expected answer.
    @Test func theWatcherReportsItsWindowsVisibility() async {
        let reports = WatcherReports()
        let watcher = WindowOcclusionReader.WatcherView { reports.values.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = watcher
        #expect(await Self.settle { !reports.values.isEmpty })
        #expect(reports.values == [window.occlusionState.contains(.visible)])
        window.contentView = nil
    }

    @Test func theSectionIsOnScreenOnlyWhileShownInAVisibleWindow() {
        #expect(StatusView.isOnScreen(shown: true, windowVisible: true))
        #expect(!StatusView.isOnScreen(shown: true, windowVisible: false))
        #expect(!StatusView.isOnScreen(shown: false, windowVisible: true))
        #expect(!StatusView.isOnScreen(shown: false, windowVisible: false))
    }

    /// The section's demand drives a real monitor: live while shown in a visible window,
    /// paused (grace periods set to zero) while covered or gone.
    @Test func theSectionDemandFollowsVisibility() async {
        let monitor = StatusMonitor(
            source: IdleStatusSource(),
            sensors: .unavailable,
            timing: StatusMonitor.Timing(downgradeToBackgroundGrace: .zero, downgradeToPausedGrace: .zero)
        )
        defer { monitor.stop() }
        monitor.setAllowed(true)

        StatusView.applyDemand(to: monitor, shown: true, windowVisible: true)
        #expect(await Self.settle { monitor.cadence == .live })
        StatusView.applyDemand(to: monitor, shown: true, windowVisible: false)
        #expect(await Self.settle { monitor.cadence == .paused })
        StatusView.applyDemand(to: monitor, shown: true, windowVisible: true)
        #expect(await Self.settle { monitor.cadence == .live })
        StatusView.applyDemand(to: monitor, shown: false, windowVisible: true)
        #expect(await Self.settle { monitor.cadence == .paused })
    }

    // MARK: - Fixtures

    private static let english = Locale(identifier: "en_US")
    /// The full capture's `collected_at`, in whole seconds.
    private static let now = Date(timeIntervalSince1970: 1_790_485_704)
    private static let failure = StatusMonitor.Failure.engineStopped(
        ErrorPresentation(EngineError.nonZeroExit(code: 2, stderrTail: ""))
    )

    /// Fewer differing pixels than this means two renders show the same thing, as in
    /// Plan 2's render tests.
    private static let minimumDifference = 1_000
    private static let gridSize = CGSize(width: 900, height: 640)
    /// A size no other render in the suite uses.
    private static let sparklineSize = CGSize(width: 244, height: 68)

    /// Task 16's full capture as the monitor reads it: 14 % GPU from IOKit, normal
    /// pressure, a battery, and the app's free space.
    private static func fullReading() throws -> StatusReading {
        StatusReading.make(
            snapshot: try StatusFixtures.full(), lastEnriched: nil, gpuUsage: 14, pressure: .normal,
            hasBattery: true, freeSpace: StatusFixtures.freeSpace, now: now
        )
    }

    /// `count` samples 120/59 s apart, ending at `now`, so 60 of them span exactly two
    /// minutes. `value` fills the percentage series; the rates and the GPU follow it.
    private static func history(count: Int, gpu: Bool = true, value: (Int) -> Double) -> StatusHistory {
        var history = StatusHistory()
        for index in 0..<count {
            let level = value(index)
            history.append(StatusSample(
                date: now.addingTimeInterval(Double(index - count + 1) * 120 / 59),
                cpu: level,
                memory: level,
                gpu: gpu ? level / 2 : nil,
                diskIO: level / 4,
                netRx: level / 50,
                netTx: level / 200,
                battery: 100 - Double(index) / 3
            ))
        }
        return history
    }

    /// A slow wave between 10 and 90.
    private nonisolated static func wave(_ index: Int) -> Double {
        50 + 40 * sin(Double(index) / 6)
    }

    private static func grid(_ reading: StatusReading?, history: StatusHistory = StatusHistory(),
                             failure: StatusMonitor.Failure? = nil) -> StatusGrid {
        StatusGrid(reading: reading, history: history, freeSpace: StatusFixtures.freeSpace, failure: failure)
    }

    private static func render(_ view: some View, in scheme: ColorScheme = .light, size: CGSize = gridSize) throws -> RenderedPixels {
        let image = try #require(RenderCheck.image(of: view, scheme: scheme, size: size))
        #expect(image.width == Int(size.width))
        #expect(image.height == Int(size.height))
        return try RenderedPixels(image)
    }

    private static func transparent(_ size: CGSize) -> RenderedPixels {
        RenderedPixels.transparent(width: Int(size.width), height: Int(size.height))
    }

    /// Checks `condition` until it holds, for at most 5 s.
    private static func settle(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

/// What the watcher reported, in order.
@MainActor
private final class WatcherReports {
    var values: [Bool] = []
}

/// A feed that never delivers a snapshot and ends only when stopped, so the monitor's
/// cadence moves only with the demands a test sets.
private struct IdleStatusSource: StatusSource {
    func open() -> StatusFeed {
        let (snapshots, continuation) = AsyncThrowingStream<SystemSnapshot, any Error>.makeStream()
        return StatusFeed(
            snapshots: snapshots,
            suspend: {},
            resume: {},
            stop: { continuation.finish(throwing: EngineError.cancelled) }
        )
    }
}
