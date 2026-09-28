import AppKit
import MoleEngine
import SwiftUI

/// Smart Clean's detail (spec §5.1). It shows one screen for `SmartCleanModel.phase` and wires
/// that screen's buttons to the model. Every screen is a value view that tests render on its own.
struct SmartCleanView: View {
    private let appModel: AppModel

    init(appModel: AppModel) {
        self.appModel = appModel
    }

    var body: some View {
        Group {
            if let model = appModel.smartClean {
                SmartCleanScreens(model: model, permissions: appModel.permissions)
            } else {
                // AppModel builds the feature in the same turn the engine becomes ready, and
                // RootView shows the main window only after that, so this never stays.
                Color.clear
            }
        }
        // Runs when the view appears, and again if the model appears later, so a first scan
        // requested before the model existed still starts.
        .task(id: appModel.smartClean.map(ObjectIdentifier.init)) {
            Self.consumePendingScan(appModel.smartClean, appModel: appModel)
            await appModel.permissions.refresh(.fullDiskAccess)
        }
        .onChange(of: appModel.pendingFirstScan) {
            Self.consumePendingScan(appModel.smartClean, appModel: appModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Full Disk Access is switched on in System Settings, so look again on every return.
            Task {
                await appModel.permissions.refresh(.fullDiskAccess)
            }
        }
    }

    /// Hands a pending first scan (onboarding's "Start first scan", later Quick Scan) to the
    /// model, which clears the flag and scans unless a run is in progress. Without a model the
    /// flag stays for when the model exists.
    static func consumePendingScan(_ model: SmartCleanModel?, appModel: AppModel) {
        guard appModel.pendingFirstScan, let model else {
            return
        }
        model.consumePendingScan(from: appModel)
    }
}

/// The screen Smart Clean shows for a phase. `.confirming` keeps the results on screen under
/// the confirmation sheet. `.refreshing` shows the scan ring, because a size check is a dry
/// run of the selection that walks every section again (Ruling 7).
enum SmartCleanScreen: Equatable, Sendable {
    case hero(note: SmartCleanNote?)
    case scanning(ScanProgress, rechecking: Bool)
    case results(CleanPreview)
    case cleaning(CleanProgress)
    case summary(CleanReport)
    case failure(SmartCleanFailure)

    /// The screen without its values: what changes of screen animate on.
    enum Kind: Hashable, Sendable {
        case hero, scanning, results, cleaning, summary, failure
    }

    static func resolve(_ phase: SmartCleanPhase) -> SmartCleanScreen {
        switch phase {
        case .idle(let note):
            .hero(note: note)
        case .scanning(let progress):
            .scanning(progress, rechecking: false)
        case .refreshing(_, let progress):
            .scanning(progress, rechecking: true)
        case .results(let preview), .confirming(let preview, _):
            .results(preview)
        case .cleaning(let progress):
            .cleaning(progress)
        case .summary(let report):
            .summary(report)
        case .failed(let failure):
            .failure(failure)
        }
    }

    /// The plan the confirmation sheet shows: exactly while the phase is `.confirming`.
    static func confirmingPlan(_ phase: SmartCleanPhase) -> CleanPlan? {
        guard case .confirming(_, let plan) = phase else {
            return nil
        }
        return plan
    }

    var kind: Kind {
        switch self {
        case .hero: .hero
        case .scanning: .scanning
        case .results: .results
        case .cleaning: .cleaning
        case .summary: .summary
        case .failure: .failure
        }
    }
}

/// Copy that several Smart Clean screens share.
enum SmartCleanText {
    /// "1 item" / "12 items". The String Catalog varies this key by plural.
    static func itemCount(_ count: Int) -> LocalizedStringResource {
        "\(count) items"
    }

    /// "1 item removed" / "12 items removed". The String Catalog varies this key by plural.
    static func removedCount(_ count: Int) -> LocalizedStringResource {
        "\(count) items removed"
    }

    /// "and 1 more" / "and 12 more", after the first few names of a list.
    static func more(_ count: Int) -> LocalizedStringResource {
        "and \(count) more"
    }

    /// **Stop**, or "Stopping…" once a stop was asked for and the engine is finishing.
    static func stopTitle(stopRequested: Bool) -> LocalizedStringResource {
        stopRequested ? "Stopping…" : "Stop"
    }

    /// What VoiceOver calls a section's expand button.
    static func expandTitle(isExpanded: Bool) -> LocalizedStringResource {
        isExpanded ? "Hide items" : "Show items"
    }

    /// The note after a stop: under the Scan button after a stopped scan, and over the
    /// results after a stopped size check.
    static func note(_ note: SmartCleanNote) -> LocalizedStringResource {
        switch note {
        case .scanStopped:
            "Scan stopped. Nothing was removed."
        case .recheckStopped:
            "Size check stopped. Nothing was removed, and the sizes are from your last scan."
        }
    }
}

/// The glass the Scan button and the scan ring share.
enum SmartCleanGlass {
    /// The `glassEffectID` of the Scan button and of the ring it morphs into.
    static let scanID = "smartClean.scan"
    /// Less than the hero's vertical spacing (24), so the button never blends with the card below it.
    static let containerSpacing: CGFloat = 12
}

/// How Smart Clean changes screens: a spring, so the Scan button morphs into the ring, or a
/// short ease under Reduce Motion, where `morphingGlass` crossfades instead of morphing.
enum SmartCleanMotion {
    static let screenSpring: Animation = .spring(response: 0.5, dampingFraction: 0.85)
    static let reducedMotionFade: Animation = .easeInOut(duration: 0.3)

    static func screenAnimation(reduceMotion: Bool) -> Animation {
        Motion.animation(screenSpring, reduceMotion: reduceMotion) ?? reducedMotionFade
    }
}

extension EnvironmentValues {
    /// The namespace `SmartCleanView` gives the Scan button and the scan ring, so the button
    /// morphs into the ring inside its one `GlassEffectContainer`. Nil when a screen is drawn
    /// on its own.
    @Entry var smartCleanGlassNamespace: Namespace.ID? = nil
}

/// A one-line note on a tinted background: a scan that stopped early or could not measure
/// every size, or a stopped size check.
struct SmartCleanBanner: View {
    let text: LocalizedStringResource

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Palette.grass)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.grass.opacity(0.14), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

/// A scan that could not run: the run problem card with **Try again**, or, when Smart Clean
/// was asked to scan before setup finished, a short card with the same button.
struct SmartCleanFailureView: View {
    let failure: SmartCleanFailure
    let retry: @MainActor () -> Void

    var body: some View {
        Group {
            switch failure {
            case .notReady:
                NotReadyCard(retry: retry)
            case .scanFailed(let presentation, let diagnostics):
                RunProblemCard(presentation: presentation, diagnostics: diagnostics, retry: retry)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `.notReady`: a scan was asked for before onboarding finished. It keeps the run problem
/// card's identifiers, so UI tests find one failure card whatever went wrong.
private struct NotReadyCard: View {
    let retry: @MainActor () -> Void

    var body: some View {
        GlassCard(cornerRadius: 24, padding: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text("Smart Clean isn't ready yet")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.text)
                } icon: {
                    Image(systemName: "hourglass")
                        .foregroundStyle(Palette.grass)
                }
                .accessibilityAddTraits(.isHeader)
                Text("Finish setting up RoomForMac, then scan again.")
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    GlassButton("Try again", action: retry)
                        .accessibilityIdentifier(AccessibilityID.runProblemRetry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 540)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Smart Clean isn't ready yet"))
        .accessibilityIdentifier(AccessibilityID.runProblemCard)
    }
}

/// The plan under the confirmation sheet, identified by its run so the sheet keeps its
/// content while it closes.
private struct ConfirmingPlan: Identifiable {
    let plan: CleanPlan

    var id: UUID {
        plan.id
    }
}

/// The screens over one model. The Scan button and the scan ring live in one
/// `GlassEffectContainer` that stays on screen, so the button morphs into the ring (spec
/// §11.4). Every other screen sits outside it, so its cards and buttons never blend.
private struct SmartCleanScreens: View {
    let model: SmartCleanModel
    let permissions: PermissionCenter

    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let screen = SmartCleanScreen.resolve(model.phase)
        let fullDiskAccess = permissions.state(.fullDiskAccess)
        ZStack {
            GlassEffectContainer(spacing: SmartCleanGlass.containerSpacing) {
                switch screen {
                case .hero(let note):
                    SmartCleanHero(
                        fullDiskAccess: fullDiskAccess,
                        blockedBy: model.blockedBy,
                        note: note,
                        scan: { model.scan() },
                        allowFullDiskAccess: allowFullDiskAccess
                    )
                case .scanning(let progress, let rechecking):
                    ScanScreen(progress: progress, rechecking: rechecking, timings: model.timings) {
                        model.stop()
                    }
                case .results, .cleaning, .summary, .failure:
                    EmptyView()
                }
            }
            switch screen {
            case .results(let preview):
                VStack(alignment: .leading, spacing: 0) {
                    if let note = model.resultsNote {
                        SmartCleanBanner(text: SmartCleanText.note(note))
                            .padding(.horizontal, 32)
                            .padding(.top, 24)
                    }
                    CleanResultsView(
                        preview: preview,
                        gateDecision: model.gateDecision,
                        blockedBy: model.blockedBy,
                        actions: actions
                    )
                }
            case .cleaning(let progress):
                ScrollView {
                    CleanProgressView(progress: progress) {
                        model.stop()
                    }
                }
            case .summary(let report):
                ScrollView {
                    CleanSummaryView(
                        report: report,
                        fullDiskAccess: fullDiskAccess,
                        done: { model.done() },
                        scanAgain: { model.scan() },
                        allowFullDiskAccess: allowFullDiskAccess
                    )
                }
            case .failure(let failure):
                SmartCleanFailureView(failure: failure) {
                    model.retry()
                }
            case .hero, .scanning:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.smartCleanGlassNamespace, glass)
        .animation(SmartCleanMotion.screenAnimation(reduceMotion: reduceMotion), value: screen.kind)
        .sheet(item: confirmation) { confirming in
            CleanConfirmSheet(
                plan: confirming.plan,
                confirm: { model.confirmClean() },
                cancel: { model.cancelConfirmation() }
            )
        }
    }

    private var actions: CleanResultsActions {
        CleanResultsActions(
            toggle: { model.toggle($0) },
            setSection: { model.setSection($0, selected: $1) },
            selectAll: { model.selectAll() },
            selectNone: { model.selectNone() },
            clean: {
                Task {
                    await model.requestClean()
                }
            },
            scanAgain: { model.scan() }
        )
    }

    /// Up exactly while the phase is `.confirming`. Closing the sheet any other way than its
    /// buttons (Escape) cancels; the model ignores a cancel in every other phase.
    private var confirmation: Binding<ConfirmingPlan?> {
        Binding(
            get: { SmartCleanScreen.confirmingPlan(model.phase).map(ConfirmingPlan.init) },
            set: { confirming in
                if confirming == nil {
                    model.cancelConfirmation()
                }
            }
        )
    }

    private func allowFullDiskAccess() {
        Task {
            await permissions.request(.fullDiskAccess)
        }
    }
}

/// The scan ring, ticking once a second for the elapsed time. The `TimelineView` exists only
/// while a scan or a size check runs, so nothing ticks otherwise.
private struct ScanScreen: View {
    let progress: ScanProgress
    let rechecking: Bool
    let timings: SectionTimings
    let stop: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if rechecking {
                Text("Your results are a while old, so Smart Clean is checking your selection's sizes again.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                ScanProgressView(
                    progress: progress,
                    fraction: progress.fraction(timings: timings, now: context.date),
                    now: context.date,
                    stop: stop
                )
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
