import SwiftUI

/// One Status card (spec §5.4): the kind's title and symbol, a big rounded figure,
/// a few details, an optional chip and the sparkline of the last 60 samples.
/// VoiceOver reads the card as one element, labelled with its summary.
struct StatusCard: View {
    private let kind: StatusCardKind
    private let reading: StatusReading
    private let history: StatusHistory
    private let freeSpace: FreeSpace?

    init(kind: StatusCardKind, reading: StatusReading, history: StatusHistory, freeSpace: FreeSpace?) {
        self.kind = kind
        self.reading = reading
        self.history = history
        self.freeSpace = freeSpace
    }

    var body: some View {
        if let content = StatusCardContent.make(kind: kind, reading: reading, history: history, freeSpace: freeSpace) {
            GlassCard(cornerRadius: 20, padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    header(content)
                    figure(content)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(content.details, id: \.self) { detail in
                            Text(detail)
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if let chartCaption = content.chartCaption {
                        Text(chartCaption)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Sparkline(points: content.points, domain: content.domain)
                        .frame(height: 44)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(content.accessibilitySummary(title: String(localized: kind.title))))
            .accessibilityIdentifier(AccessibilityID.statusCard(kind))
        }
    }

    private func header(_ content: StatusCardContent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text(kind.title)
            } icon: {
                Image(systemName: kind.systemImage)
            }
            .font(.headline)
            .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 8)
            if let chip = content.chip {
                StatusChip(chip)
            }
        }
    }

    @ViewBuilder
    private func figure(_ content: StatusCardContent) -> some View {
        if let figure = content.figure {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(figure)
                    .font(Typography.hero(size: 44))
                    .foregroundStyle(content.figureIsSize ? Palette.grass : Palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let caption = content.caption {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
        } else {
            // No value to show, for example GPU usage the Mac does not report.
            Text(content.spokenFigure)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.textSecondary)
                .frame(minHeight: 52, alignment: .bottomLeading)
        }
    }
}

/// What one Status card shows, worked out from a reading, so the card and VoiceOver
/// say the same thing and tests can read it without rendering.
struct StatusCardContent: Sendable, Equatable {
    /// The big rounded figure; nil when there is no value, and `spokenFigure` shows instead.
    var figure: String?
    /// Sizes are drawn in grass, every other figure in the text colour.
    var figureIsSize: Bool
    /// Small words after the figure: "of 17.2 GB", "free", "down".
    var caption: String?
    /// The figure as VoiceOver reads it: "12.7 GB used of 17.2 GB", or "Usage unavailable".
    var spokenFigure: String
    /// One short phrase per line under the figure.
    var details: [String]
    var chip: StatusChip.Model?
    /// Names the chart when it plots something other than the figure: the Disk card's
    /// figure is free space, its chart reads and writes.
    var chartCaption: String?
    /// The sparkline: `StatusHistory.series` puts the newest sample at x 59, so a short
    /// history fills in from the right.
    var points: [SeriesPoint]
    /// `0...100` for percentages; nil for rates (automatic, at least 1).
    var domain: ClosedRange<Double>?
    /// "12% to 95% over the last 2 minutes": the chart's range and the time its
    /// samples cover. Nil below two samples.
    var historyPhrase: String?

    /// The card for `kind`, or nil when the reading has nothing for it.
    ///
    /// Numbers, percentages, the time span and the summary's list follow `locale`
    /// (tests pin `en_US`); sizes and rates come from `ByteText` in the user's locale.
    static func make(
        kind: StatusCardKind,
        reading: StatusReading,
        history: StatusHistory,
        freeSpace: FreeSpace?,
        locale: Locale = .autoupdatingCurrent
    ) -> StatusCardContent? {
        let format = StatusFormat(locale: locale)
        switch kind {
        case .cpu:
            return reading.cpu.map { cpu($0, history: history, format: format) }
        case .gpu:
            return reading.gpu.map { gpu($0, history: history, format: format) }
        case .memory:
            return reading.memory.map { memory($0, history: history, format: format) }
        case .disk:
            return reading.disk.map { disk($0, freeSpace: freeSpace, history: history, format: format) }
        case .network:
            return reading.network.map { network($0, history: history, format: format) }
        case .battery:
            return reading.battery.map { battery($0, history: history, format: format) }
        }
    }

    /// The card's one VoiceOver label: its title, figure, details, chip and the span
    /// its chart covers, as a narrow list in `locale` ("a, b, c" in English).
    func accessibilitySummary(title: String, locale: Locale = .autoupdatingCurrent) -> String {
        var parts = [title, spokenFigure] + details
        if let chip {
            parts.append(chip.text)
        }
        if let historyPhrase {
            parts.append(historyPhrase)
        }
        return parts.formatted(.list(type: .and, width: .narrow).locale(locale))
    }

    /// The engine's battery status (the word after the percentage in `pmset -g batt`)
    /// in plain language. An unknown word is shown as data; "Unknown" shows nothing.
    static func batteryStatus(_ status: String) -> String? {
        switch status.lowercased() {
        case "charged":
            String(localized: "Charged")
        case "charging":
            String(localized: "Charging")
        case "discharging":
            String(localized: "On battery")
        case "finishing":
            String(localized: "Finishing charge")
        case "ac":
            String(localized: "Not charging")
        case "", "unknown":
            nil
        default:
            status
        }
    }

    /// The memory-pressure chip; none while the level is unknown.
    static func pressureChip(_ pressure: MemoryPressure) -> StatusChip.Model? {
        switch pressure {
        case .unknown:
            nil
        case .normal:
            StatusChip.Model(text: String(localized: "Pressure: normal"), tone: .calm)
        case .warning:
            StatusChip.Model(text: String(localized: "Pressure: high"), tone: .caution)
        case .critical:
            StatusChip.Model(text: String(localized: "Pressure: critical"), tone: .alert)
        }
    }

    // MARK: - One card per kind

    private static func cpu(_ cpu: StatusReading.CPU, history: StatusHistory, format: StatusFormat) -> StatusCardContent {
        let figure = format.percent(cpu.usage)
        var details: [String] = []
        if let cores = cpu.cores {
            details.append(String(localized: "\(cores) cores", locale: format.locale))
        }
        if let load = cpu.load1 {
            details.append(String(localized: "Load \(format.decimal(load))", locale: format.locale))
        }
        return StatusCardContent(
            figure: figure, figureIsSize: false, caption: nil, spokenFigure: figure, details: details, chip: nil,
            plot: .percent, points: history.series(\.cpu), history: history, format: format
        )
    }

    private static func gpu(_ gpu: StatusReading.GPU, history: StatusHistory, format: StatusFormat) -> StatusCardContent {
        let figure = gpu.usage.map { format.percent($0) }
        var details: [String] = []
        if !gpu.name.isEmpty {
            details.append(gpu.name)
        }
        if let cores = gpu.cores {
            details.append(String(localized: "\(cores) cores", locale: format.locale))
        }
        return StatusCardContent(
            figure: figure, figureIsSize: false, caption: nil,
            spokenFigure: figure ?? String(localized: "Usage unavailable", locale: format.locale),
            details: details, chip: nil, plot: .percent, points: history.series(\.gpu), history: history, format: format
        )
    }

    private static func memory(_ memory: StatusReading.Memory, history: StatusHistory, format: StatusFormat) -> StatusCardContent {
        let used = format.size(memory.used)
        let total = format.size(memory.total)
        var details: [String] = []
        if let swap = memory.swapUsed {
            details.append(
                swap > 0
                    ? String(localized: "Swap \(format.size(swap))", locale: format.locale)
                    : String(localized: "No swap used", locale: format.locale)
            )
        }
        return StatusCardContent(
            figure: used, figureIsSize: true, caption: String(localized: "of \(total)", locale: format.locale),
            spokenFigure: String(localized: "\(used) used of \(total)", locale: format.locale),
            details: details, chip: pressureChip(memory.pressure),
            plot: .percent, points: history.series(\.memory), history: history, format: format
        )
    }

    private static func disk(
        _ disk: StatusReading.Disk, freeSpace: FreeSpace?, history: StatusHistory, format: StatusFormat
    ) -> StatusCardContent {
        // The app's own reading counts purgeable space as free, like Finder (Ruling 16).
        let freeBytes = freeSpace?.importantAvailable
            ?? disk.free
            ?? max(Int64(clamping: disk.total) - Int64(clamping: disk.used), 0)
        let figure = ByteText.string(freeBytes)
        var details: [String] = []
        if let fraction = usedFraction(disk: disk, freeSpace: freeSpace) {
            details.append(String(localized: "\(format.percent(fraction * 100)) used", locale: format.locale))
        }
        let chip = disk.smartFailing
            ? StatusChip.Model(text: String(localized: "Disk may be failing", locale: format.locale), tone: .alert)
            : nil
        return StatusCardContent(
            figure: figure, figureIsSize: true, caption: String(localized: "free", locale: format.locale),
            spokenFigure: String(localized: "\(figure) free", locale: format.locale), details: details, chip: chip,
            plot: .readsAndWrites, points: history.series(\.diskIO), history: history, format: format
        )
    }

    private static func network(_ network: StatusReading.Network, history: StatusHistory, format: StatusFormat) -> StatusCardContent {
        let down = format.rate(network.rxMBs)
        var details = [String(localized: "Up \(format.rate(network.txMBs))", locale: format.locale)]
        if let name = network.busiestInterface, !name.isEmpty {
            details.append(String(localized: "Busiest: \(name)", locale: format.locale))
        }
        return StatusCardContent(
            figure: down, figureIsSize: false, caption: String(localized: "down", locale: format.locale),
            spokenFigure: String(localized: "\(down) down", locale: format.locale), details: details, chip: nil,
            plot: .rate, points: networkPoints(history), history: history, format: format
        )
    }

    private static func battery(_ battery: StatusReading.Battery, history: StatusHistory, format: StatusFormat) -> StatusCardContent {
        let figure = format.percent(battery.percent)
        var details: [String] = []
        if let status = batteryStatus(battery.status) {
            details.append(status)
        }
        if let cycles = battery.cycleCount {
            details.append(String(localized: "\(cycles) cycles", locale: format.locale))
        }
        if let capacity = battery.capacityPercent {
            details.append(String(localized: "Maximum capacity \(format.percent(Double(capacity)))", locale: format.locale))
        }
        return StatusCardContent(
            figure: figure, figureIsSize: false, caption: nil, spokenFigure: figure, details: details, chip: nil,
            plot: .percent, points: history.series(\.battery), history: history, format: format
        )
    }

    // MARK: - Charts

    /// What a chart plots, which sets its scale, the words for its values and the
    /// sentence VoiceOver reads about its range.
    private enum Plot {
        case percent, rate, readsAndWrites
    }

    private init(
        figure: String?, figureIsSize: Bool, caption: String?, spokenFigure: String, details: [String],
        chip: StatusChip.Model?, plot: Plot, points: [SeriesPoint], history: StatusHistory, format: StatusFormat
    ) {
        self.figure = figure
        self.figureIsSize = figureIsSize
        self.caption = caption
        self.spokenFigure = spokenFigure
        self.details = details
        self.chip = chip
        chartCaption = plot == .readsAndWrites ? String(localized: "Reads and writes", locale: format.locale) : nil
        self.points = points
        domain = plot == .percent ? 0...100 : nil
        historyPhrase = Self.historyPhrase(plot: plot, values: points.map(\.value), history: history, format: format)
    }

    /// The lowest and highest values and the time from the oldest sample to the newest.
    private static func historyPhrase(plot: Plot, values: [Double], history: StatusHistory, format: StatusFormat) -> String? {
        guard values.count >= 2, let lowest = values.min(), let highest = values.max(),
              let oldest = history.first, let newest = history.last else {
            return nil
        }
        let seconds = Int(newest.date.timeIntervalSince(oldest.date).rounded())
        guard seconds > 0 else {
            return nil
        }
        let span = format.span(seconds: seconds)
        switch plot {
        case .percent:
            let low = format.percent(lowest)
            let high = format.percent(highest)
            return String(localized: "\(low) to \(high) over the last \(span)", locale: format.locale)
        case .rate:
            let low = format.rate(lowest)
            let high = format.rate(highest)
            return String(localized: "\(low) to \(high) over the last \(span)", locale: format.locale)
        case .readsAndWrites:
            let low = format.rate(lowest)
            let high = format.rate(highest)
            return String(localized: "Reads and writes \(low) to \(high) over the last \(span)", locale: format.locale)
        }
    }

    /// Received plus sent, sample by sample, like the engine's own network history.
    private static func networkPoints(_ history: StatusHistory) -> [SeriesPoint] {
        var received: [Int: Double] = [:]
        for point in history.series(\.netRx) {
            received[point.index] = point.value
        }
        return history.series(\.netTx).compactMap { sent in
            received[sent.index].map { SeriesPoint(index: sent.index, value: $0 + sent.value) }
        }
    }

    /// How full the disk is: from the app's reading when there is one, so it agrees
    /// with the free figure, otherwise from the engine's disk.
    private static func usedFraction(disk: StatusReading.Disk, freeSpace: FreeSpace?) -> Double? {
        if let freeSpace, freeSpace.total > 0 {
            return freeSpace.usedFraction
        }
        guard disk.total > 0 else {
            return nil
        }
        return Double(disk.used) / Double(disk.total)
    }
}

/// Number formatting for one locale.
private struct StatusFormat {
    let locale: Locale

    /// "42%" for 42.
    func percent(_ value: Double) -> String {
        (value / 100).formatted(FloatingPointFormatStyle<Double>.Percent(locale: locale).precision(.fractionLength(0)))
    }

    /// "2.50".
    func decimal(_ value: Double) -> String {
        value.formatted(FloatingPointFormatStyle<Double>(locale: locale).precision(.fractionLength(2)))
    }

    /// "2 minutes", "1 minute, 58 seconds".
    func span(seconds: Int) -> String {
        Duration.seconds(seconds).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .wide).locale(locale)
        )
    }

    /// "12.7 GB" (`ByteText`).
    func size(_ bytes: UInt64) -> String {
        ByteText.string(Int64(clamping: bytes))
    }

    /// "49 KB/s" for MiB per second (`ByteText`).
    func rate(_ mebibytes: Double) -> String {
        ByteText.perSecond(mebibytes: mebibytes)
    }
}

/// How strongly a chip speaks. The words carry the meaning; the tint only repeats it.
enum StatusTone: Sendable, Equatable {
    case calm, caution, alert

    var token: Palette.Token {
        switch self {
        case .calm: .moss
        case .caution: .grass
        case .alert: .clay
        }
    }
}

/// A small tinted capsule on a card or the health line, drawn like Plan 2's
/// `PermissionChip`.
struct StatusChip: View {
    struct Model: Sendable, Equatable {
        var text: String
        var tone: StatusTone
    }

    private let model: Model

    init(_ model: Model) {
        self.model = model
    }

    var body: some View {
        let tint = Palette.color(model.tone.token)
        Text(model.text)
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(Palette.text)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: .capsule)
            .overlay(Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1))
    }
}
