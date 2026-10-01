import SwiftUI

/// What fills a sidebar row's rounded rectangle.
enum SidebarRowFill: Sendable, Equatable {
    /// The selected row: tinted glass, which slides to the next selection.
    case selection
    /// A hovered row that is not selected: a faint wash.
    case hover
    case none

    static func resolve(isSelected: Bool, isHovered: Bool) -> SidebarRowFill {
        if isSelected {
            return .selection
        }
        return isHovered ? .hover : .none
    }
}

/// The main window's sidebar. It draws no panel of its own, so the section's backdrop runs under
/// it; its rows are large, with filled icons; the selection is one glass pill that morphs from row
/// to row; Settings sits at the bottom.
///
/// The window's title bar is hidden, so the traffic lights sit over the top of the sidebar.
struct Sidebar: View {
    static let width: CGFloat = 232
    /// Room above the first row for the traffic lights.
    static let topInset: CGFloat = 56
    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 12
    /// The selection pill's glass tint: `moss` marks the sidebar selection (spec §11.1).
    static let selectionTint: Color = Palette.moss.opacity(0.45)
    /// How the pill moves to the next row.
    static let selectionMorph: Animation = .spring(response: 0.35, dampingFraction: 0.82)
    /// The pill's glass ID. It moves to the selected row, so the glass morphs there instead of
    /// fading out in one row and in at the next.
    static let selectionGlassID = "sidebar.selection"

    @Binding var selection: SidebarSection
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: Self.rowSpacing) {
                VStack(spacing: Self.rowSpacing) {
                    ForEach(SidebarSection.allCases) { section in
                        Button {
                            selection = section
                        } label: {
                            SidebarRowLabel(
                                title: section.title,
                                systemImage: section.systemImage,
                                isSelected: section == selection,
                                glassID: section.rawValue,
                                glass: glass
                            )
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(section.shortcut), modifiers: .command)
                        .accessibilityAddTraits(section == selection ? .isSelected : [])
                        .accessibilityIdentifier(AccessibilityID.sidebarRow(section))
                    }
                }
            }
            // Scoped to the rows, so the detail column swaps sections without animating.
            .animation(Motion.animation(Self.selectionMorph, reduceMotion: reduceMotion), value: selection)

            Spacer(minLength: 24)

            SettingsLink {
                SidebarRowLabel(title: "Settings", systemImage: "gearshape", isSelected: false, glassID: "settings", glass: glass)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.sidebarSettings)
        }
        .padding(.top, Self.topInset)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.sidebar)
    }
}

/// A row's icon and title. The selected row's content sits in the selection glass; a hovered row
/// sits on a faint wash.
private struct SidebarRowLabel: View {
    let title: LocalizedStringResource
    let systemImage: String
    let isSelected: Bool
    /// The row's own glass ID while it is not selected. Each glass shape needs one.
    let glassID: String
    let glass: Namespace.ID

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    /// Gold into green, top to bottom, so the filled symbols read as solid objects.
    private static let iconStyle = LinearGradient(
        colors: [Palette.grass, Palette.action],
        startPoint: .top,
        endPoint: .bottom
    )

    private static let shape = RoundedRectangle(cornerRadius: Sidebar.cornerRadius, style: .continuous)

    private var fill: SidebarRowFill {
        SidebarRowFill.resolve(isSelected: isSelected, isHovered: isHovered)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .symbolVariant(.fill)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Self.iconStyle)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: Sidebar.rowHeight)
        .contentShape(Self.shape)
        .background {
            if fill == .hover {
                Self.shape.fill(Palette.text.opacity(0.06))
            }
        }
        .modifier(selectionSurface)
        .animation(Motion.animation(Motion.hover, reduceMotion: reduceMotion), value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var selectionSurface: SelectionSurface {
        SelectionSurface(
            policy: GlassSurfacePolicy.resolve(reduceTransparency: reduceTransparency),
            isSelected: fill == .selection,
            glassID: fill == .selection ? Sidebar.selectionGlassID : glassID,
            glass: glass,
            shape: Self.shape,
            transition: Motion.glassTransition(reduceMotion: reduceMotion)
        )
    }
}

/// The selection pill: tinted glass around the selected row's content, or a solid tint under
/// Reduce Transparency. Every other row carries `.identity` glass, which draws nothing, so the
/// pill's glass ID can move between rows.
private struct SelectionSurface: ViewModifier {
    let policy: GlassSurfacePolicy
    let isSelected: Bool
    let glassID: String
    let glass: Namespace.ID
    let shape: RoundedRectangle
    let transition: GlassEffectTransition

    func body(content: Content) -> some View {
        switch policy {
        case .glass:
            content
                .glassEffect(isSelected ? Glass.regular.tint(Sidebar.selectionTint) : .identity, in: shape)
                .glassEffectID(glassID, in: glass)
                .glassEffectTransition(transition)
        case .solid:
            content
                .background {
                    if isSelected {
                        shape.fill(Sidebar.selectionTint)
                    }
                }
        }
    }
}

/// The sidebar beside `detail`, divided by a hairline. The caller puts the backdrop behind both.
struct SidebarLayout<Detail: View>: View {
    @Binding var selection: SidebarSection
    private let detail: Detail

    init(selection: Binding<SidebarSection>, @ViewBuilder detail: () -> Detail) {
        _selection = selection
        self.detail = detail()
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection)
                .ignoresSafeArea(edges: .vertical)
            Rectangle()
                .fill(Palette.text.opacity(0.08))
                .frame(width: 1)
                .ignoresSafeArea(edges: .vertical)
                .accessibilityHidden(true)
            detail
                .detailColumnFrame()
        }
    }
}
