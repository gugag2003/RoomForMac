import SwiftUI

/// A scan in progress (spec §5.1, Ruling 21): the Scan button's glass grown into a ring that
/// fills with the weighted fraction, the bytes found so far, the time since the scan started
/// (never an estimate of the time left), the section being scanned, and **Stop**.
struct ScanProgressView: View {
    static let ringSize: CGFloat = 240
    static let lineWidth: CGFloat = 10

    private let progress: ScanProgress
    private let fraction: Double
    private let now: Date
    private let stop: @MainActor () -> Void

    @Environment(\.smartCleanGlassNamespace) private var sharedNamespace
    @Namespace private var ownNamespace

    init(progress: ScanProgress, fraction: Double, now: Date, stop: @escaping @MainActor () -> Void) {
        self.progress = progress
        self.fraction = fraction
        self.now = now
        self.stop = stop
    }

    /// `fraction` within 0...1; anything that is not a finite number reads as 0.
    static func clamped(_ fraction: Double) -> Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }

    /// Whole seconds since `start`, never negative: "0:42", "12:05".
    static func elapsedText(since start: Date, now: Date) -> String {
        let seconds = max(0, Int64(now.timeIntervalSince(start).rounded(.down)))
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    /// The section being scanned, or "Getting ready…" before the first one starts.
    static func sectionTitle(_ current: String?) -> LocalizedStringResource {
        guard let current else {
            return "Getting ready…"
        }
        return CleanSectionCatalog.title(current)
    }

    /// What VoiceOver reads for the ring: "42 percent, App caches, 1.2 GB found, 0:42 elapsed".
    static func accessibilityValue(
        fraction: Double, section: String?, found: String, elapsed: String
    ) -> LocalizedStringResource {
        let percent = Int((clamped(fraction) * 100).rounded(.down))
        let title = String(localized: sectionTitle(section))
        return "\(percent) percent, \(title), \(found) found, \(elapsed) elapsed"
    }

    var body: some View {
        let fraction = Self.clamped(fraction)
        let found = ByteText.string(progress.foundBytes)
        let elapsed = Self.elapsedText(since: progress.startedAt, now: now)
        VStack(spacing: 20) {
            Text("Scanning")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)

            ZStack {
                Circle()
                    .stroke(Palette.moss.opacity(0.35), lineWidth: Self.lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Palette.moss, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(verbatim: found)
                        .font(Typography.hero(size: 44))
                        .foregroundStyle(Palette.grass)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("found")
                        .foregroundStyle(Palette.textSecondary)
                    Text(verbatim: elapsed)
                        .font(Typography.numeral)
                        .foregroundStyle(Palette.text)
                        .padding(.top, 6)
                }
                .padding(.horizontal, 28)
            }
            .padding(Self.lineWidth)
            .frame(width: Self.ringSize, height: Self.ringSize)
            .morphingGlass(
                id: SmartCleanGlass.scanID,
                in: sharedNamespace ?? ownNamespace,
                shape: .circle,
                tint: nil,
                interactive: false
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Scan progress"))
            .accessibilityValue(Text(Self.accessibilityValue(
                fraction: fraction, section: progress.current, found: found, elapsed: elapsed
            )))
            .accessibilityIdentifier(AccessibilityID.smartCleanProgress)

            Text(Self.sectionTitle(progress.current))
                .font(.headline)
                .foregroundStyle(Palette.text)

            GlassButton(.secondary, action: stop) {
                Text(SmartCleanText.stopTitle(stopRequested: progress.stopRequested))
            }
            .disabled(progress.stopRequested)
            .accessibilityIdentifier(AccessibilityID.smartCleanStop)
        }
    }
}
