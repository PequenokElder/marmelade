import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Settings

struct Adjustments: Equatable {
    var exposure = 0.0       // -1...1   midtone brightness, never clips
    var contrast = 1.2       // 0.6...1.5 smooth S-curve, pinned at black and white
    var saturation = 1.15    // 0...2    bounded, can't overshoot a channel
    var vibrance = 0.3       // -1...1   boosts dull colors more than vivid ones
    var warmth = 0.0         // -1...1
    var colorLimit = 0.9     // 0.6...1  ceiling that boosted colors ease toward
    var protectSkin = true   // boost skin hues less
    var antiBanding = true   // sub-visible dither so gradients don't step
    var colorNoise = 0.3     // 0...1   smooths blotchy chroma (JPEG blocks, color noise) before boosts
    var grainAmount = 0.15   // 0...1
    var grainSize = 1.0      // 0.5...3, relative to image width

    // Film look
    var rolloff = 0.4        // 0...1   lifted toe + soft highlight shoulder
    var coolShadows = 0.3    // -1...1  shadows lean cool blue/teal (+) or warm (-)
    var bloom = 0.15         // 0...1   soft glow on highlights
    var halation = 0.2       // 0...1   red glow around bright highlights
    var glowThreshold = 0.75 // 0.4...0.95 how bright before bloom/halation start
    var vignette = 0.2       // 0...1
    var highlightWarmth = 0.0 // -1...1  highlights lean warm (+) or cool (-)
    var tint = 0.0           // -1...1  green (-) to magenta (+)

    static let startingPoint = Adjustments()
    static let neutral = Adjustments(exposure: 0, contrast: 1, saturation: 1, vibrance: 0, warmth: 0,
                                     colorLimit: 1, protectSkin: false, antiBanding: false, colorNoise: 0,
                                     grainAmount: 0, grainSize: 1,
                                     rolloff: 0, coolShadows: 0, bloom: 0, halation: 0,
                                     glowThreshold: 0.75, vignette: 0)
}

/// Where the finished JPEG's colors are encoded.
enum OutputSpace: String, CaseIterable, Identifiable {
    case matchSource = "Match source"
    case sRGB = "sRGB"
    case displayP3 = "Display P3"
    var id: String { rawValue }
}

/// Controls for developing RAW files (ignored for JPEG/PNG/etc.).
struct RawSettings: Equatable {
    var temperature = 0.0   // -1...1  white balance, + = warmer (relative to the camera's setting)
    var tint = 0.0          // -1...1  + = magenta, - = green
    var exposure = 0.0      // EV, -3...3 (true RAW exposure, recovers highlights / lifts shadows)
    var toneBoost = 1.0     // 0...1   strength of Apple's default RAW tone rendering (1 = standard)
    var shadows = 0.0       // -1...1  + lifts shadows, - deepens them
    var sharpness = 0.0     // 0...1   extra RAW sharpening
}

/// The camera/decoder defaults for a file, so sliders can be relative to them.
struct RawBaseline {
    let temperature: Float, tint: Float, shadowBias: Float, sharpness: Float
    init(_ raw: CIRAWFilter) {
        temperature = raw.neutralTemperature
        tint = raw.neutralTint
        shadowBias = raw.shadowBias
        sharpness = raw.sharpnessAmount
    }
}

extension RawSettings {
    func apply(to raw: CIRAWFilter, baseline b: RawBaseline) {
        raw.neutralTemperature = b.temperature * Float(pow(2, temperature * 0.5))
        raw.neutralTint = b.tint + Float(tint * 60)
        raw.exposure = Float(exposure)
        raw.boostAmount = Float(max(0, min(1, toneBoost)))
        raw.shadowBias = b.shadowBias - Float(shadows * 20)      // higher bias = darker shadows
        raw.sharpnessAmount = max(0, b.sharpness + Float(sharpness))
    }
}

/// Per-photo exposure and white balance, set on one image and applied on top of the global look.
/// RAW files get true RAW development changes; everything else is corrected in linear light.
struct PhotoFix: Equatable {
    var exposure = 0.0      // EV, -3...3
    var temperature = 0.0   // -1...1, + = warmer
    var tint = 0.0          // -1...1, + = magenta

    var isNeutral: Bool { self == PhotoFix() }
}

extension RawSettings {
    /// This file's own adjustments stacked on the global RAW settings.
    func adding(_ fix: PhotoFix) -> RawSettings {
        var s = self
        s.exposure = max(-6, min(6, exposure + fix.exposure))
        s.temperature = temperature + fix.temperature
        s.tint = tint + fix.tint
        return s
    }
}

/// A RAW file kept open for the preview, so slider moves re-develop it without reloading the file.
final class RAWPreview {
    private let filter: CIRAWFilter
    private let baseline: RawBaseline
    private let lock = NSLock()

    init?(url: URL, maxDimension: Int) {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        let longest = max(f.nativeSize.width, f.nativeSize.height)
        if longest > 0 { f.scaleFactor = Float(min(1, Double(maxDimension) / Double(longest))) }
        filter = f
        baseline = RawBaseline(f)
    }

    func develop(_ settings: RawSettings) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        settings.apply(to: filter, baseline: baseline)
        return filter.outputImage.map(Renderer.clamp01)
    }
}

struct Look: Equatable {
    var adjustments: Adjustments
    var lut: LUT?
    var lutIntensity: Double
    /// Non-RAW photos only: RAW photos take their per-photo fix through RawSettings instead.
    var fix = PhotoFix()

    static let original = Look(adjustments: .neutral, lut: nil, lutIntensity: 1)
}

// MARK: - LUT

enum LUTError: LocalizedError {
    case unsupported(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let m), .malformed(let m): return m
        }
    }
}

/// A 3D LUT parsed from an Adobe/Resolve `.cube` file, stored as RGBA float data for CIColorCube.
final class LUT: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let url: URL
    let size: Int
    let cubeData: Data

    init(url: URL) throws {
        self.url = url
        self.name = url.deletingPathExtension().lastPathComponent

        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            if line.hasPrefix("LUT_1D_SIZE") {
                throw LUTError.unsupported("\(url.lastPathComponent) is a 1D LUT. Only 3D .cube LUTs are supported.")
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last ?? "") ?? 0
                values.reserveCapacity(size * size * size * 4)
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) {
                values.append(contentsOf: [r, g, b, 1])
            }
        }

        guard size >= 2, values.count == size * size * size * 4 else {
            throw LUTError.malformed("\(url.lastPathComponent) isn't a valid 3D .cube file.")
        }
        self.size = size
        self.cubeData = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func == (a: LUT, b: LUT) -> Bool { a.id == b.id }
}

// MARK: - Safe saturation cube

/// Saturation and vibrance are applied in HSV terms through a small 3D cube instead of per-channel
/// math. Brightness (max channel) never changes and saturation is remapped with 1-(1-s)^g, so a
/// channel can never be pushed past 0, which is what causes flat blocks of color.
private struct SaturationKey: Hashable {
    var saturation: Double, vibrance: Double, colorLimit: Double, protectSkin: Bool
}

private func makeSaturationCube(_ k: SaturationKey, dimension n: Int = 40) -> Data {
    let cap = max(0.6, min(1, k.colorLimit))
    let knee = cap * 0.7
    var out = [Float]()
    out.reserveCapacity(n * n * n * 4)

    for bi in 0..<n {
        for gi in 0..<n {
            for ri in 0..<n {
                let r = Double(ri) / Double(n - 1)
                let g = Double(gi) / Double(n - 1)
                let b = Double(bi) / Double(n - 1)
                let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn

                var nr = r, ng = g, nb = b
                if d > 1e-9 && mx > 0 {
                    let s = d / mx
                    var gain = k.saturation * (1 + k.vibrance * (1 - s))
                    gain = max(0, gain)

                    if k.protectSkin && gain > 1 {
                        var h: Double
                        if mx == r { h = 60 * (((g - b) / d).truncatingRemainder(dividingBy: 6)) }
                        else if mx == g { h = 60 * ((b - r) / d + 2) }
                        else { h = 60 * ((r - g) / d + 4) }
                        if h < 0 { h += 360 }
                        let dist = (h - 25) / 22
                        let skin = exp(-dist * dist)
                        gain = 1 + (gain - 1) * (1 - 0.65 * skin)
                    }

                    var s2 = 1 - pow(1 - s, gain)
                    if s2 > s {
                        if s2 > knee { s2 = knee + (cap - knee) * (1 - exp(-(s2 - knee) / (cap - knee))) }
                        s2 = max(s, s2)
                    }
                    let f = s2 / s
                    nr = mx - (mx - r) * f
                    ng = mx - (mx - g) * f
                    nb = mx - (mx - b) * f
                }
                out.append(contentsOf: [Float(nr), Float(ng), Float(nb), 1])
            }
        }
    }
    return out.withUnsafeBufferPointer { Data(buffer: $0) }
}

// MARK: - Renderer

final class Renderer {
    static let shared = Renderer()

    private var contexts: [String: CIContext] = [:]
    private var cubeCache: (SaturationKey, Data)?
    private let lock = NSLock()

    /// Photos are processed in their own (gamma-encoded) color space so curves and LUTs
    /// behave the way they do in photo editors.
    static func rgbSpace(_ cs: CGColorSpace?) -> CGColorSpace {
        // Linear spaces (what RAW decoding hands back) are processed and exported as gamma-encoded sRGB.
        if let cs, cs.model == .rgb, !((cs.name as String?) ?? "").localizedCaseInsensitiveContains("linear") { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    static func resolveSpace(_ source: CGColorSpace?, _ choice: OutputSpace) -> CGColorSpace {
        switch choice {
        case .matchSource: return rgbSpace(source)
        case .sRGB: return CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        }
    }

    private func context(for cs: CGColorSpace) -> CIContext {
        let key = (cs.name as String?) ?? "icc-\((cs.copyICCData() as Data?)?.hashValue ?? 0)"
        lock.lock(); defer { lock.unlock() }
        if let c = contexts[key] { return c }
        let c = CIContext(options: [
            .workingColorSpace: cs,
            .outputColorSpace: cs,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
        ])
        contexts[key] = c
        return c
    }

    private func saturationCube(_ key: SaturationKey) -> Data {
        lock.lock()
        if let cached = cubeCache, cached.0 == key { lock.unlock(); return cached.1 }
        lock.unlock()
        let data = makeSaturationCube(key)
        lock.lock(); cubeCache = (key, data); lock.unlock()
        return data
    }

    // MARK: Pipeline

    /// exposure/warmth -> contrast -> saturation/vibrance -> LUT -> grain / dither
    func apply(_ look: Look, to input: CIImage) -> CIImage {
        let a = look.adjustments
        var img = input

        // First, so the boosts below don't amplify blotchy chroma.
        if a.colorNoise > 0 { img = reduceColorNoise(img, amount: a.colorNoise) }

        if !look.fix.isNeutral { img = applyPhotoFix(img, look.fix) }

        // Exposure + warmth: x + k*x*(1-x) per channel. Pinned at 0 and 1, so highlights can't clip.
        let ke = a.exposure * 0.9
        let kw = a.warmth * 0.25
        let kt = a.tint * 0.1
        if ke != 0 || kw != 0 || kt != 0 {
            func clampK(_ v: Double) -> Double { max(-1, min(1, v)) }
            func coeffs(_ k: Double) -> CIVector { CIVector(x: 0, y: 1 + k, z: -k, w: 0) }
            let f = CIFilter.colorPolynomial()
            f.inputImage = img
            f.redCoefficients = coeffs(clampK(ke + kw))
            f.greenCoefficients = coeffs(clampK(ke - kt))
            f.blueCoefficients = coeffs(clampK(ke - kw))
            img = f.outputImage ?? img
        }

        // Contrast: smooth S-curve x + a*(-2x^3 + 3x^2 - x). Pinned at 0 and 1; no hard clipping.
        if a.contrast != 1 {
            let c = max(-0.8, min(1, 2 * (a.contrast - 1)))
            let v = CIVector(x: 0, y: 1 - c, z: 3 * c, w: -2 * c)
            let f = CIFilter.colorPolynomial()
            f.inputImage = img
            f.redCoefficients = v
            f.greenCoefficients = v
            f.blueCoefficients = v
            img = f.outputImage ?? img
        }

        if a.saturation < 0.02 {
            img = luminance(img)   // true black and white, weighted by luma instead of the brightest channel
        } else if a.saturation != 1 || a.vibrance != 0 {
            let key = SaturationKey(saturation: a.saturation, vibrance: a.vibrance,
                                    colorLimit: a.colorLimit, protectSkin: a.protectSkin)
            let f = CIFilter.colorCube()
            f.inputImage = img
            f.cubeDimension = 40
            f.cubeData = saturationCube(key)
            img = f.outputImage ?? img
        }

        if a.rolloff > 0 { img = filmRolloff(img, amount: a.rolloff) }
        if a.coolShadows != 0 { img = shadowTone(img, amount: a.coolShadows) }
        if a.highlightWarmth != 0 { img = highlightTone(img, amount: a.highlightWarmth) }

        if let lut = look.lut, look.lutIntensity > 0 {
            let cube = CIFilter.colorCube()
            cube.inputImage = img
            cube.cubeDimension = Float(lut.size)
            cube.cubeData = lut.cubeData
            if let graded = cube.outputImage {
                if look.lutIntensity >= 0.999 {
                    img = graded
                } else {
                    let mix = CIFilter.dissolveTransition()
                    mix.inputImage = img
                    mix.targetImage = graded
                    mix.time = Float(look.lutIntensity)
                    img = mix.outputImage?.cropped(to: input.extent) ?? graded
                }
            }
        }

        if a.bloom > 0 || a.halation > 0 {
            img = addGlow(img, bloom: a.bloom, halation: a.halation, threshold: a.glowThreshold)
        }
        if a.vignette > 0 { img = addVignette(img, amount: a.vignette) }

        if a.grainAmount > 0 {
            img = addNoise(to: img, amount: a.grainAmount, size: a.grainSize)
        } else if a.antiBanding {
            img = addNoise(to: img, amount: 0, size: 0, ditherOnly: true)
        }

        return img.cropped(to: input.extent)
    }

    // MARK: Film look

    /// x + t(1-x)^3 + s(x^2 - x^3): a toe that lifts only the deepest blacks, and a shoulder whose
    /// slope eases to (1 - s) at white. Exactly 1 at white, so highlights roll off instead of clipping.
    private func filmRolloff(_ img: CIImage, amount k: Double) -> CIImage {
        let t = 0.03 * k, s = 0.12 * k
        let v = CIVector(x: t, y: 1 - 3 * t, z: 3 * t + s, w: -t - s)
        let f = CIFilter.colorPolynomial()
        f.inputImage = img
        f.redCoefficients = v
        f.greenCoefficients = v
        f.blueCoefficients = v
        return f.outputImage ?? img
    }

    /// Luminance as a gray image, optionally remapped through (x - t) / (1 - t) and clamped.
    private func luminance(_ img: CIImage, threshold t: Double = 0) -> CIImage {
        let s = 1 / (1 - t)
        let m = CIFilter.colorMatrix()
        m.inputImage = img
        let row = CIVector(x: 0.299 * s, y: 0.587 * s, z: 0.114 * s, w: 0)
        m.rVector = row; m.gVector = row; m.bVector = row
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: -t * s, y: -t * s, z: -t * s, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = m.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage ?? img
    }

    private func screen(_ top: CIImage, over base: CIImage) -> CIImage {
        let f = CIFilter.screenBlendMode()
        f.inputImage = top
        f.backgroundImage = base
        return f.outputImage?.cropped(to: base.extent) ?? base
    }

    private func blurred(_ img: CIImage, radius: Double) -> CIImage {
        let f = CIFilter.gaussianBlur()
        f.inputImage = img.clampedToExtent()
        f.radius = Float(radius)
        return f.outputImage?.cropped(to: img.extent) ?? img
    }

    /// Exposure and white balance as gains in linear light. White balance is normalized so it never
    /// brightens (the strongest channel stays put), so it can't push highlights into clipping.
    private func applyPhotoFix(_ img: CIImage, _ fix: PhotoFix) -> CIImage {
        var r = pow(2, 0.4 * fix.temperature)
        var b = pow(2, -0.4 * fix.temperature)
        var g = pow(2, -0.25 * fix.tint)
        let top = max(r, g, b)
        r /= top; g /= top; b /= top
        let ev = pow(2, fix.exposure)

        let toLinear = CIFilter.sRGBToneCurveToLinear()
        toLinear.inputImage = img
        let gains = CIFilter.colorMatrix()
        gains.inputImage = toLinear.outputImage
        gains.rVector = CIVector(x: r * ev, y: 0, z: 0, w: 0)
        gains.gVector = CIVector(x: 0, y: g * ev, z: 0, w: 0)
        gains.bVector = CIVector(x: 0, y: 0, z: b * ev, w: 0)
        gains.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let toGamma = CIFilter.linearToSRGBToneCurve()
        toGamma.inputImage = gains.outputImage
        return toGamma.outputImage?.cropped(to: img.extent) ?? img
    }

    /// Chroma-only smoothing: blur the image, then put the original luminance back on top
    /// (result = blurred + lumaOriginal - lumaBlurred). Detail and brightness stay; blotchy color
    /// noise and JPEG chroma blocks get averaged out. Radius scales with image width.
    private func reduceColorNoise(_ img: CIImage, amount: Double) -> CIImage {
        let soft = blurred(img, radius: img.extent.width * 0.008 * amount)

        // Blend filters clamp every intermediate to 0...1, so build delta = lumaOrig - lumaSoft
        // in a shifted form that stays in range: 0.5*Lo + (0.5 - 0.5*Ls) = 0.5 + delta/2.
        func scaled(_ image: CIImage?, by s: Double, bias: Double) -> CIImage? {
            let m = CIFilter.colorMatrix()
            m.inputImage = image
            m.rVector = CIVector(x: s, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: s, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: s, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            m.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
            return m.outputImage
        }

        let sum = CIFilter.linearDodgeBlendMode()
        sum.inputImage = scaled(luminance(img), by: 0.5, bias: 0)
        sum.backgroundImage = scaled(luminance(soft), by: -0.5, bias: 0.5)
        guard let delta = scaled(sum.outputImage, by: 2, bias: -1) else { return img }

        let result = CIFilter.linearDodgeBlendMode()
        result.inputImage = delta
        result.backgroundImage = soft
        return result.outputImage?.cropped(to: img.extent) ?? img
    }

    /// Tints one tonal range using a luma weight, screened on so it can never clip.
    /// `weightCoefficients` shape the weight from luma (e.g. (1,-2,1,0) = (1-L)^2 for shadows).
    private func tonalTint(_ img: CIImage, weight: CIVector, tint: (r: Double, g: Double, b: Double)) -> CIImage {
        let poly = CIFilter.colorPolynomial()
        poly.inputImage = luminance(img)
        poly.redCoefficients = weight; poly.greenCoefficients = weight; poly.blueCoefficients = weight

        let m = CIFilter.colorMatrix()
        m.inputImage = poly.outputImage
        m.rVector = CIVector(x: tint.r, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: tint.g, y: 0, z: 0, w: 0)
        m.bVector = CIVector(x: tint.b, y: 0, z: 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let layer = m.outputImage else { return img }
        return screen(layer, over: img)
    }

    /// Shadows lean cool blue/teal (amount > 0) or warm amber (amount < 0).
    private func shadowTone(_ img: CIImage, amount k: Double) -> CIImage {
        let weight = CIVector(x: 1, y: -2, z: 1, w: 0)          // (1 - L)^2
        let a = abs(k)
        return k > 0
            ? tonalTint(img, weight: weight, tint: (0, 0.025 * a, 0.08 * a))
            : tonalTint(img, weight: weight, tint: (0.08 * a, 0.03 * a, 0))
    }

    /// Highlights lean warm gold (amount > 0) or cool blue (amount < 0).
    private func highlightTone(_ img: CIImage, amount k: Double) -> CIImage {
        let weight = CIVector(x: 0, y: 0, z: 1, w: 0)           // L^2
        let a = abs(k)
        return k > 0
            ? tonalTint(img, weight: weight, tint: (0.09 * a, 0.045 * a, 0))
            : tonalTint(img, weight: weight, tint: (0, 0.025 * a, 0.08 * a))
    }

    /// Bloom: soft white glow from highlights. Halation: red glow hugging the outside edge of them.
    private func addGlow(_ img: CIImage, bloom: Double, halation: Double, threshold t: Double) -> CIImage {
        let width = img.extent.width
        let highlights = luminance(img, threshold: t)
        var out = img

        if bloom > 0 {
            let glow = blurred(highlights, radius: width * 0.012)
            let m = CIFilter.colorMatrix()
            m.inputImage = glow
            let s = bloom * 0.9
            m.rVector = CIVector(x: s, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: s, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: s, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            if let layer = m.outputImage { out = screen(layer, over: out) }
        }

        if halation > 0 {
            let wide = blurred(highlights, radius: width * 0.03)
            let tight = blurred(highlights, radius: width * 0.006)

            // Red-orange tint of the wide glow.
            let tint = CIFilter.colorMatrix()
            tint.inputImage = wide
            let s = halation * 1.4
            tint.rVector = CIVector(x: s, y: 0, z: 0, w: 0)
            tint.gVector = CIVector(x: 0.22 * s, y: 0, z: 0, w: 0)
            tint.bVector = CIVector(x: 0.05 * s, y: 0, z: 0, w: 0)
            tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)

            // Knock the glow out of the highlight itself so it reads as an outline.
            let knock = CIFilter.colorMatrix()
            knock.inputImage = tight
            let inv = CIVector(x: -2, y: 0, z: 0, w: 0)
            knock.rVector = inv
            knock.gVector = CIVector(x: 0, y: -2, z: 0, w: 0)
            knock.bVector = CIVector(x: 0, y: 0, z: -2, w: 0)
            knock.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            knock.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = knock.outputImage
            clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
            clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

            let ring = CIFilter.multiplyCompositing()
            ring.inputImage = tint.outputImage
            ring.backgroundImage = clamp.outputImage
            if let layer = ring.outputImage { out = screen(layer, over: out) }
        }
        return out
    }

    private func addVignette(_ img: CIImage, amount: Double) -> CIImage {
        let e = img.extent
        let f = CIFilter.vignetteEffect()
        f.inputImage = img
        f.center = CGPoint(x: e.midX, y: e.midY)
        f.radius = Float(hypot(e.width, e.height) * 0.42)
        f.intensity = Float(amount)
        f.falloff = 0.6
        return f.outputImage?.cropped(to: e) ?? img
    }

    /// Film grain: monochrome noise whose cell size scales with image width (so previews match
    /// full-size exports), lightly softened. With `ditherOnly` it's a ~1.5/255 per-pixel dither.
    private func addNoise(to img: CIImage, amount: Double, size: Double, ditherOnly: Bool = false) -> CIImage {
        let extent = img.extent
        // The generator's alpha is random too; force it to 1 first or the matrix un-premultiplies by it.
        guard var noise = CIFilter.randomGenerator().outputImage?
            .cropped(to: extent).settingAlphaOne(in: extent) else { return img }

        // Grain is pixel-level noise softened by a Gaussian, never enlarged blocks, so it looks
        // the same at preview size and at full resolution. Softness scales with image width.
        let sigma = ditherOnly ? 0 : size * extent.width / 2000 * 0.5
        // Blurring white noise by sigma divides its std by ~2*sqrt(pi)*sigma; undo that so the
        // Amount slider means the same strength at every size.
        let comp = sigma > 0 ? grainCompensation(sigma: sigma) : 1
        let gain: Double = ditherOnly ? 1.5 / 255 / 0.167 : amount * 0.36 * comp

        // Gray noise, centered on zero: (r+g+b)/3 has mean 0.5, std ~0.167.
        let w = gain / 3
        let m = CIFilter.colorMatrix()
        m.inputImage = noise
        m.rVector = CIVector(x: w, y: w, z: w, w: 0)
        m.gVector = CIVector(x: w, y: w, z: w, w: 0)
        m.bVector = CIVector(x: w, y: w, z: w, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: -gain / 2, y: -gain / 2, z: -gain / 2, w: 1)
        noise = m.outputImage ?? noise

        if sigma > 0.3 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = noise.clampedToExtent()
            blur.radius = Float(sigma)
            noise = blur.outputImage?.cropped(to: extent) ?? noise
        } else {
            noise = noise.cropped(to: extent)
        }

        let add = CIFilter.linearDodgeBlendMode()
        add.inputImage = noise
        add.backgroundImage = img
        return add.outputImage?.cropped(to: extent) ?? img
    }

    /// Gain needed to keep grain strength constant as the blur softens it. CIGaussianBlur doesn't
    /// follow the textbook white-noise formula, so this is a table measured on the real pipeline:
    /// (sigma, how much the blur reduces the noise's std).
    private func grainCompensation(sigma: Double) -> Double {
        let table: [(Double, Double)] = [(0.3, 1.0), (0.5, 1.9), (0.6, 2.35), (0.75, 2.8), (0.9, 3.3), (1.0, 3.55),
                                         (1.2, 4.2), (1.5, 4.85), (1.8, 5.4), (2.0, 5.7), (3.0, 6.3), (4.5, 6.2)]
        if sigma <= table[0].0 { return 1 }
        for i in 1..<table.count where sigma <= table[i].0 {
            let (x0, y0) = table[i - 1], (x1, y1) = table[i]
            return y0 + (y1 - y0) * (sigma - x0) / (x1 - x0)
        }
        return table.last!.1
    }

    // MARK: Preview

    // MARK: RAW

    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "raw",
        "pef", "srw", "3fr", "fff", "iiq", "erf", "mrw", "kdc", "dcr", "mef", "mos", "rwl",
    ]

    static func isRAW(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .rawImage) { return true }
        return false
    }

    /// RAW comes back as extended-range linear light; clamp to 0...1 so the curves and LUTs
    /// (which expect display-range values) behave like they do on a JPEG.
    static func clamp01(_ img: CIImage) -> CIImage {
        let f = CIFilter.colorClamp()
        f.inputImage = img
        f.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        f.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return f.outputImage ?? img
    }

    /// Full-resolution image, developed through Apple's RAW engine when the file is RAW.
    static func loadFull(url: URL, raw settings: RawSettings = RawSettings()) -> CIImage? {
        if isRAW(url), let raw = CIRAWFilter(imageURL: url) {
            settings.apply(to: raw, baseline: RawBaseline(raw))
            if let out = raw.outputImage { return clamp01(out) }
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }

    static func loadPreviewSource(url: URL, maxDimension: Int) -> CIImage? {
        if isRAW(url), let raw = CIRAWFilter(imageURL: url) {
            // Decode at reduced size: far faster than developing the full sensor image.
            let longest = max(raw.nativeSize.width, raw.nativeSize.height)
            if longest > 0 { raw.scaleFactor = Float(min(1, Double(maxDimension) / Double(longest))) }
            if let out = raw.outputImage { return clamp01(out) }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return CIImage(cgImage: cg)
    }

    func renderPreview(source: CIImage, look: Look, output: OutputSpace = .matchSource) -> CGImage? {
        let cs = Self.resolveSpace(source.colorSpace, output)
        let out = apply(look, to: source)
        return context(for: cs).createCGImage(out, from: source.extent, format: .RGBA8, colorSpace: cs)
    }

    // MARK: Export

    func export(from url: URL, to dest: URL, look: Look, quality: Double,
                raw: RawSettings = RawSettings(), output: OutputSpace = .matchSource) throws {
        guard let img = Self.loadFull(url: url, raw: raw) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let cs = Self.resolveSpace(img.colorSpace, output)
        let out = apply(look, to: img)
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        try context(for: cs).writeJPEGRepresentation(of: out, to: dest, colorSpace: cs, options: [qualityKey: quality])
    }
}
