import SwiftUI

/// The full-window landscape behind a surface (spec §11.3): the scene's photo, or its fallback gradient,
/// under a canvas wash, drifting slowly, and crossfading when the scene changes.
///
/// Place it with `.background { BackdropView(scene: …).ignoresSafeArea() }`. `focus` pulls the photo from
/// fully blurred (0) to sharp (1); callers animate it.
///
/// - Reduce Transparency: a solid canvas, with no photo and no blur.
/// - Reduce Motion: no drift.
struct BackdropView: View {
    /// Opacity of the canvas wash over the picture, for legibility.
    static let washOpacity = 0.4

    /// The drift redraws at most this often.
    static let driftFrameInterval: TimeInterval = 1.0 / 30.0

    private let scene: BackdropScene
    private let focus: Double
    private let loader: BackdropImageLoader

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Shown?
    @State private var driftStart = Date()

    init(scene: BackdropScene, focus: Double = 0) {
        self.init(scene: scene, focus: focus, loader: .shared)
    }

    /// Tests pass a loader over a fixture bundle.
    init(scene: BackdropScene, focus: Double, loader: BackdropImageLoader) {
        self.scene = scene
        self.focus = focus
        self.loader = loader
        // A scene loaded before (by an earlier backdrop, say) shows at once instead of fading in again.
        _shown = State(initialValue: loader.cachedEntry(for: scene).map { Shown(scene: scene, images: $0.images) })
    }

    var body: some View {
        ZStack {
            Palette.canvas
            if !reduceTransparency {
                drift
                Palette.canvas.opacity(Self.washOpacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: scene) { await show(scene) }
        .onChange(of: reduceMotion) { _, isReduced in
            // Start the next loop from rest instead of jumping back to where the old one was.
            if !isReduced {
                driftStart = Date()
            }
        }
    }

    private var drift: some View {
        TimelineView(.animation(minimumInterval: Self.driftFrameInterval, paused: reduceMotion)) { context in
            GeometryReader { proxy in
                let pose = KenBurns.pose(
                    at: context.date.timeIntervalSince(driftStart),
                    in: proxy.size,
                    reduceMotion: reduceMotion
                )
                layers
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(pose.scale)
                    .offset(pose.offset)
            }
        }
        .clipped()
        .backgroundExtensionEffect()
        .animation(.easeInOut(duration: Motion.sectionCrossfade / .seconds(1)), value: shown?.scene)
    }

    private var layers: some View {
        ZStack {
            if let shown {
                BackdropLayer(scene: shown.scene, images: shown.images, focus: focus)
                    .id(shown.scene)
                    .transition(.opacity)
            }
        }
    }

    /// Loads the scene's photo off the main thread, then swaps it in; the swap is the crossfade.
    private func show(_ scene: BackdropScene) async {
        let loader = self.loader
        let images = await Task.detached(priority: .userInitiated) {
            loader.images(for: scene)
        }.value
        guard !Task.isCancelled else {
            return
        }
        shown = Shown(scene: scene, images: images)
    }

    private struct Shown {
        let scene: BackdropScene
        let images: BackdropImages?
    }
}

/// One scene's picture: the photo pair pulled into focus, or the fallback gradient when there is no photo.
struct BackdropLayer: View {
    let scene: BackdropScene
    let images: BackdropImages?
    let focus: Double

    static func clampedFocus(_ focus: Double) -> Double {
        min(max(focus, 0), 1)
    }

    var body: some View {
        if let images {
            // The blurred photo stays fully opaque underneath, so the canvas never shows through mid-fade.
            ZStack {
                picture(images.blurred)
                picture(images.sharp)
                    .opacity(Self.clampedFocus(focus))
            }
        } else {
            LinearGradient(
                colors: scene.fallbackColors.map { Palette.color($0) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    /// Fills the available space, cropping the photo instead of letterboxing it.
    private func picture(_ image: CGImage) -> some View {
        Color.clear
            .overlay {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
    }
}
