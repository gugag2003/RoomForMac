import SwiftUI

/// Screen 2: what is free. Scans and previews are unlimited; cleanup is free up
/// to 1 GB, once. A meter fills to show the allowance.
struct FreeToExploreStep: View {
    /// The free cleanup allowance, shown as "1 GB".
    static let freeAllowanceBytes: Int64 = 1_000_000_000
    /// How long the meter takes to fill, in seconds.
    static let meterFillDuration = 1.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var meterFill = 0.0

    var body: some View {
        GlassCard(cornerRadius: 24, padding: 28) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Unlimited scans and previews")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.freeAllowanceBytes, format: .byteCount(style: .file))
                        .font(Typography.hero(size: 48))
                        .foregroundStyle(Palette.text)
                    AllowanceMeter(fill: reduceMotion ? 1 : meterFill)
                        .frame(height: 12)
                    Text("1 GB of free cleanup, once")
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("1 GB of free cleanup, once"))

                Text("Upgrade once for unlimited cleanup — every future version included.")
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("No account, no card.")
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            guard !reduceMotion else {
                return
            }
            withAnimation(.easeInOut(duration: Self.meterFillDuration)) {
                meterFill = 1
            }
        }
    }
}

/// A capsule track in `moss` with a `grass` fill from the leading edge.
private struct AllowanceMeter: View {
    let fill: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.moss.opacity(0.5))
                Capsule()
                    .fill(Palette.grass)
                    .frame(width: proxy.size.width * min(max(fill, 0), 1))
            }
        }
    }
}
