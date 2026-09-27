/// The landscape behind each surface (spec §11.3).
///
/// Photos are looked up by `resourceName` in the app's `Backgrounds` folder. None ship until the owner
/// picks them, so every scene also names the palette tokens of the gradient drawn in their place.
enum BackdropScene: String, CaseIterable, Sendable {
    /// Fitz Roy and Laguna de los Tres at sunrise, Patagonia.
    case onboarding
    /// Yosemite Valley from Tunnel View.
    case smartClean
    /// Cerro Torre and the Fitz Roy massif, Patagonia.
    case uninstaller
    /// Half Dome, Yosemite.
    case terrain
    /// Torres del Paine, Patagonia.
    case status

    /// The photo's file name inside `Backgrounds/`, without its extension: `backdrop-smartClean`.
    var resourceName: String { "backdrop-\(rawValue)" }

    /// The fallback gradient, from top leading to bottom trailing.
    ///
    /// Only background tokens appear: `clay` is kept for destructive confirmations and the text tokens
    /// for text. Each scene gets its own mix so sections still look different without photos.
    var fallbackColors: [Palette.Token] {
        switch self {
        case .onboarding: [.grass, .moss, .canvas]     // first light on the spires, down to the lake
        case .smartClean: [.canvas, .moss, .action]    // pale sky over a green valley floor
        case .uninstaller: [.surface, .moss, .grass]   // ice and granite above dry steppe
        case .terrain: [.grass, .action]               // warm granite into dark forest
        case .status: [.canvas, .grass, .moss]         // pale sky, tan steppe, olive scrub
        }
    }
}
