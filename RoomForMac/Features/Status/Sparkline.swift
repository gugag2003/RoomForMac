import Charts
import SwiftUI

/// A card's history as a small Swift Charts area-and-line chart (spec §5.4): the
/// last 60 samples at x positions 0…59, with no axes, legend or animation.
///
/// Percentages pass `0...100`. Rates pass nil, which scales from 0 to the largest
/// value but never below 1, so idle noise stays a flat line (research §8). A single
/// sample has no line yet, so it shows as a dot.
struct Sparkline: View {
    private let points: [SeriesPoint]
    private let domain: ClosedRange<Double>?

    init(points: [SeriesPoint], domain: ClosedRange<Double>?) {
        self.points = points
        self.domain = domain
    }

    /// The sample positions every chart spans: one per `StatusHistory` slot.
    static let xDomain: ClosedRange<Int> = 0...59

    /// `domain`, or 0 up to the largest finite value, at least 1.
    static func yDomain(points: [SeriesPoint], domain: ClosedRange<Double>?) -> ClosedRange<Double> {
        if let domain {
            return domain
        }
        let largest = points.map(\.value).filter(\.isFinite).max() ?? 0
        return 0...max(1, largest)
    }

    /// `value` inside `domain`, so a stray reading cannot draw outside the chart.
    /// NaN gives the lower bound.
    static func clamped(_ value: Double, to domain: ClosedRange<Double>) -> Double {
        guard !value.isNaN else {
            return domain.lowerBound
        }
        return min(max(value, domain.lowerBound), domain.upperBound)
    }

    /// The marks' labels. The chart is hidden from VoiceOver (the card's summary
    /// speaks for it), so they are never shown and stay out of the String Catalog.
    private static let sampleLabel = "sample"
    private static let valueLabel = "value"

    var body: some View {
        let yDomain = Self.yDomain(points: points, domain: domain)
        Chart {
            ForEach(points, id: \.index) { point in
                let value = Self.clamped(point.value, to: yDomain)
                AreaMark(x: .value(Self.sampleLabel, point.index), y: .value(Self.valueLabel, value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(
                        .linearGradient(
                            colors: [Palette.moss.opacity(0.45), Palette.moss.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                LineMark(x: .value(Self.sampleLabel, point.index), y: .value(Self.valueLabel, value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Palette.moss)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            if points.count == 1, let point = points.first {
                PointMark(
                    x: .value(Self.sampleLabel, point.index),
                    y: .value(Self.valueLabel, Self.clamped(point.value, to: yDomain))
                )
                .symbolSize(36)
                .foregroundStyle(Palette.moss)
            }
        }
        .chartXScale(domain: Self.xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
        // A reading arrives every 2 s; the chart jumps to it and never animates.
        .transaction { $0.animation = nil }
    }
}
