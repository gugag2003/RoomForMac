import SwiftUI

/// Screen 6: admin access, explained and never requested. There is no password
/// field anywhere in RoomForMac: when a later update lets the user pick
/// system-level items, macOS itself shows the password prompt for that run.
struct AdminAccessStep: View {
    static let circleSize: CGFloat = 112

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(Palette.action)
                .symbolEffect(.breathe, isActive: !reduceMotion)
                .frame(width: Self.circleSize, height: Self.circleSize)
                .glassSurface(GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency), in: .circle)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Admin access")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .accessibilityAddTraits(.isHeader)
                Text("RoomForMac only asks for your password when you pick system-level items, and macOS draws that prompt, never us. Nothing is requested now.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("System-level items arrive in a later update.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
