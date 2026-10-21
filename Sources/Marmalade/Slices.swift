import Foundation

/// A saved look: every slider plus the LUT (by name) and its intensity.
struct LookSlice: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var adjustments: Adjustments
    var lutName: String?
    var lutIntensity: Double = 1

    /// Starters written on first launch only. Delete or edit freely.
    static let starters: [LookSlice] = {
        func make(_ name: String, _ edit: (inout Adjustments) -> Void) -> LookSlice {
            var a = Adjustments.neutral
            a.colorLimit = 0.9; a.protectSkin = true; a.antiBanding = true; a.colorNoise = 0.3
            edit(&a)
            return LookSlice(name: name, adjustments: a, lutName: nil)
        }
        return [
            make("Fresh Squeeze") {
                $0.contrast = 1.3; $0.saturation = 1.3; $0.vibrance = 0.4
                $0.rolloff = 0.2; $0.bloom = 0.1; $0.vignette = 0.1; $0.grainAmount = 0.05
            },
            make("Marmalade") {
                $0.warmth = 0.3; $0.contrast = 1.25; $0.saturation = 1.1; $0.vibrance = 0.25
                $0.rolloff = 0.5; $0.coolShadows = 0.35; $0.bloom = 0.2; $0.halation = 0.3
                $0.vignette = 0.3; $0.grainAmount = 0.2; $0.grainSize = 1.2
            },
            make("Pith") {
                $0.exposure = 0.1; $0.contrast = 1.05; $0.saturation = 0.85; $0.vibrance = 0.1
                $0.rolloff = 0.6; $0.coolShadows = 0.15; $0.bloom = 0.1; $0.vignette = 0.1; $0.grainAmount = 0.1
            },
        ]
    }()
}

// Tolerant decoding: a Slice saved by an older version still loads after new sliders are added.
extension Adjustments: Codable {
    enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, vibrance, warmth, colorLimit, protectSkin, antiBanding
        case colorNoise, grainAmount, grainSize, rolloff, coolShadows, bloom, halation, glowThreshold, vignette
        case highlightWarmth, tint
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(vibrance, forKey: .vibrance)
        try c.encode(warmth, forKey: .warmth)
        try c.encode(colorLimit, forKey: .colorLimit)
        try c.encode(protectSkin, forKey: .protectSkin)
        try c.encode(antiBanding, forKey: .antiBanding)
        try c.encode(colorNoise, forKey: .colorNoise)
        try c.encode(grainAmount, forKey: .grainAmount)
        try c.encode(grainSize, forKey: .grainSize)
        try c.encode(rolloff, forKey: .rolloff)
        try c.encode(coolShadows, forKey: .coolShadows)
        try c.encode(bloom, forKey: .bloom)
        try c.encode(halation, forKey: .halation)
        try c.encode(glowThreshold, forKey: .glowThreshold)
        try c.encode(vignette, forKey: .vignette)
        try c.encode(highlightWarmth, forKey: .highlightWarmth)
        try c.encode(tint, forKey: .tint)
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? vibrance
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? warmth
        colorLimit = try c.decodeIfPresent(Double.self, forKey: .colorLimit) ?? colorLimit
        protectSkin = try c.decodeIfPresent(Bool.self, forKey: .protectSkin) ?? protectSkin
        antiBanding = try c.decodeIfPresent(Bool.self, forKey: .antiBanding) ?? antiBanding
        colorNoise = try c.decodeIfPresent(Double.self, forKey: .colorNoise) ?? colorNoise
        grainAmount = try c.decodeIfPresent(Double.self, forKey: .grainAmount) ?? grainAmount
        grainSize = try c.decodeIfPresent(Double.self, forKey: .grainSize) ?? grainSize
        rolloff = try c.decodeIfPresent(Double.self, forKey: .rolloff) ?? rolloff
        coolShadows = try c.decodeIfPresent(Double.self, forKey: .coolShadows) ?? coolShadows
        bloom = try c.decodeIfPresent(Double.self, forKey: .bloom) ?? bloom
        halation = try c.decodeIfPresent(Double.self, forKey: .halation) ?? halation
        glowThreshold = try c.decodeIfPresent(Double.self, forKey: .glowThreshold) ?? glowThreshold
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? vignette
        highlightWarmth = try c.decodeIfPresent(Double.self, forKey: .highlightWarmth) ?? highlightWarmth
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? tint
    }
}
