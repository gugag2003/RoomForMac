import MoleEngine
import SwiftUI

/// The last step before a Smart Clean run (spec §5.1, §10): the total, the item count, the
/// sections they come from, and the permanent-deletion sentence, verbatim. **Clean** is the
/// destructive (clay) button and **Cancel** answers Escape. Neither is the default button, so
/// Return never removes anything.
struct CleanConfirmSheet: View {
    /// Spec §5.1, verbatim.
    static let permanenceNote: LocalizedStringResource = "These files are removed permanently; apps recreate caches as needed."

    /// How many of the paths sent to the engine come from one section.
    struct SectionCount: Equatable, Sendable {
        let section: String
        let count: Int
    }

    private let plan: CleanPlan
    private let confirm: @MainActor () -> Void
    private let cancel: @MainActor () -> Void

    init(plan: CleanPlan, confirm: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void) {
        self.plan = plan
        self.confirm = confirm
        self.cancel = cancel
    }

    /// "4.2 GB", or "at least 4.2 GB" when a size in the plan is unknown.
    static func totalText(_ plan: CleanPlan) -> String {
        plan.hasUnknownSizes ? ByteText.atLeast(plan.bytes) : ByteText.string(plan.bytes)
    }

    /// The engine paths per section, in the plan's section order. They add up to
    /// `plan.enginePaths.count`: a covered child that goes with its ancestor is not counted,
    /// and a path listed twice counts once.
    static func sectionCounts(_ plan: CleanPlan) -> [SectionCount] {
        let sent = Set(plan.enginePaths)
        var counted = Set<String>()
        var counts: [String: Int] = [:]
        for item in plan.items {
            let path = CleanSelection.normalize(item.path)
            guard sent.contains(path), counted.insert(path).inserted else {
                continue
            }
            counts[item.section, default: 0] += 1
        }
        return plan.sections.compactMap { section in
            counts[section].map { SectionCount(section: section, count: $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Clean these items?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.text)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Self.totalText(plan))
                    .font(Typography.hero(size: 44))
                    .foregroundStyle(Palette.grass)
                Text(SmartCleanText.itemCount(plan.enginePaths.count))
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.sectionCounts(plan), id: \.section) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: CleanSectionCatalog.systemImage(entry.section))
                            .foregroundStyle(Palette.action)
                            .frame(width: 20)
                        Text(CleanSectionCatalog.title(entry.section))
                            .foregroundStyle(Palette.text)
                        Spacer(minLength: 12)
                        Text(SmartCleanText.itemCount(entry.count))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Text(Self.permanenceNote)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Spacer()
                GlassButton("Cancel", prominence: .secondary, action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.smartCleanConfirmCancel)
                GlassButton(.destructive, action: confirm) {
                    Text("Clean")
                }
                .accessibilityIdentifier(AccessibilityID.smartCleanConfirm)
            }
        }
        .padding(28)
        .frame(width: 460)
    }
}
