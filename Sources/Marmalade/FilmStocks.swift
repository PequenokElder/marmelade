import Foundation

/// Built-in film looks. These are hand-tuned approximations of each stock's general character
/// (color balance, contrast, saturation, grain, halation), not measured profiles of the real film.
enum FilmStocks {
    private static func stock(_ id: String, _ name: String, _ edit: (inout Adjustments) -> Void) -> LookSlice {
        var a = Adjustments.neutral
        a.colorLimit = 0.9; a.protectSkin = true; a.antiBanding = true; a.colorNoise = 0.3
        a.glowThreshold = 0.75
        edit(&a)
        return LookSlice(id: UUID(uuidString: id)!, name: name, adjustments: a, lutName: nil)
    }

    static let all: [LookSlice] = [
        // Warm, golden, saturated consumer color negative
        stock("A0000000-0000-0000-0000-000000000001", "Gold 200") {
            $0.exposure = 0.05; $0.warmth = 0.35; $0.contrast = 1.22; $0.saturation = 1.2; $0.vibrance = 0.2
            $0.tint = -0.1; $0.rolloff = 0.35; $0.highlightWarmth = 0.5
            $0.bloom = 0.15; $0.halation = 0.25; $0.vignette = 0.2; $0.grainAmount = 0.3; $0.grainSize = 1.0
        },
        // Soft, low-contrast, creamy highlights, flattering skin
        stock("A0000000-0000-0000-0000-000000000002", "Portra 400") {
            $0.exposure = 0.08; $0.warmth = 0.12; $0.contrast = 1.05; $0.saturation = 0.95; $0.vibrance = 0.2
            $0.colorLimit = 0.85; $0.rolloff = 0.55; $0.coolShadows = 0.15; $0.highlightWarmth = 0.2
            $0.bloom = 0.15; $0.halation = 0.1; $0.vignette = 0.12; $0.grainAmount = 0.22; $0.grainSize = 0.9
        },
        // Punchy, vivid, fine grain
        stock("A0000000-0000-0000-0000-000000000003", "Ektar 100") {
            $0.warmth = 0.05; $0.contrast = 1.3; $0.saturation = 1.45; $0.vibrance = 0.1; $0.colorLimit = 0.95
            $0.rolloff = 0.2; $0.coolShadows = 0.1; $0.highlightWarmth = 0.1
            $0.bloom = 0.05; $0.halation = 0.05; $0.vignette = 0.1; $0.grainAmount = 0.08; $0.grainSize = 0.6
        },
        // Cool, pastel, green-leaning
        stock("A0000000-0000-0000-0000-000000000004", "Fuji 400H") {
            $0.exposure = 0.1; $0.warmth = -0.1; $0.contrast = 1.05; $0.saturation = 0.9; $0.vibrance = 0.25
            $0.tint = -0.25; $0.rolloff = 0.55; $0.coolShadows = 0.4; $0.highlightWarmth = -0.15
            $0.bloom = 0.15; $0.halation = 0.05; $0.vignette = 0.1; $0.grainAmount = 0.22; $0.grainSize = 0.9
        },
        // Tungsten-balanced night stock: cool shadows, strong red halos around lights
        stock("A0000000-0000-0000-0000-000000000005", "Tungsten 800") {
            $0.warmth = -0.35; $0.contrast = 1.2; $0.saturation = 1.1; $0.vibrance = 0.2
            $0.rolloff = 0.4; $0.coolShadows = 0.5; $0.highlightWarmth = 0.25
            $0.bloom = 0.35; $0.halation = 0.85; $0.glowThreshold = 0.65
            $0.vignette = 0.2; $0.grainAmount = 0.35; $0.grainSize = 1.2
        },
        // Saturated slide film
        stock("A0000000-0000-0000-0000-000000000006", "Velvia 50") {
            $0.contrast = 1.35; $0.saturation = 1.6; $0.vibrance = 0.0; $0.colorLimit = 1.0
            $0.rolloff = 0.1; $0.highlightWarmth = 0.1
            $0.bloom = 0.05; $0.vignette = 0.15; $0.grainAmount = 0.06; $0.grainSize = 0.6
        },
        // Classic black and white
        stock("A0000000-0000-0000-0000-000000000007", "Tri-X 400") {
            $0.saturation = 0; $0.vibrance = 0; $0.contrast = 1.35; $0.rolloff = 0.3
            $0.bloom = 0.05; $0.vignette = 0.25; $0.grainAmount = 0.55; $0.grainSize = 1.3
        },
    ]
}
