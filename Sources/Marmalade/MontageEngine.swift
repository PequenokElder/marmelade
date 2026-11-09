import AVFoundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - Settings

enum MontageLayoutMode: String, CaseIterable, Identifiable {
    case auto = "Auto", two = "2", three = "3", four = "4"
    var id: String { rawValue }
}

enum MontageOrder: String, CaseIterable, Identifiable {
    case listed = "As listed", captured = "Capture time", color = "Color flow"
    var id: String { rawValue }
}

enum MontageTransition: String, CaseIterable, Identifiable {
    case cut = "Cut", fade = "Fade", push = "Push"
    var id: String { rawValue }
}

enum MontageQuality: String, CaseIterable, Identifiable {
    case full = "1080 × 1920", fast = "720 × 1280"
    var id: String { rawValue }
    var size: CGSize { self == .full ? CGSize(width: 1080, height: 1920) : CGSize(width: 720, height: 1280) }
}

// MARK: - Layouts

/// How one frame of the video divides the vertical canvas.
enum MontageLayout: Equatable {
    case single, stack2, stack3, hero2, grid4

    var count: Int {
        switch self { case .single: return 1; case .stack2: return 2; case .stack3, .hero2: return 3; case .grid4: return 4 }
    }

    var name: String {
        switch self {
        case .single: return "1 full"
        case .stack2: return "2 stacked"
        case .stack3: return "3 stacked"
        case .hero2: return "1 large + 2"
        case .grid4: return "2 × 2 grid"
        }
    }

    /// Slot rectangles in top-left-origin canvas coordinates, whole pixels.
    func slots(canvas: CGSize, gap g: CGFloat) -> [CGRect] {
        let W = canvas.width, H = canvas.height
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
        }
        switch self {
        case .single:
            return [r(0, 0, W, H)]
        case .stack2:
            let h = (H - g) / 2
            return [r(0, 0, W, h), r(0, h + g, W, h)]
        case .stack3:
            let h = (H - 2 * g) / 3
            return (0..<3).map { r(0, CGFloat($0) * (h + g), W, h) }
        case .hero2:
            let top = (H - g) * 0.52, bottom = (H - g) - top, w = (W - g) / 2
            return [r(0, 0, W, top), r(0, top + g, w, bottom), r(w + g, top + g, w, bottom)]
        case .grid4:
            let w = (W - g) / 2, h = (H - g) / 2
            return [r(0, 0, w, h), r(w + g, 0, w, h), r(0, h + g, w, h), r(w + g, h + g, w, h)]
        }
    }
}

struct MontageScene: Equatable {
    var layout: MontageLayout
    var photos: [Int]      // indices into the photo list, in slot order
}

// MARK: - Photo analysis

struct PhotoInput {
    var url: URL
    var fix: PhotoFix
    var name: String
}

struct PhotoInfo {
    var input: PhotoInput
    var aspect: Double            // upright width / height
    var focus: CGPoint?           // normalized, origin bottom-left: center of faces or the salient subject
    var date: Date
    var color: SIMD3<Double>      // average color, 0...1
}

enum MontageEngine {
    // MARK: Analysis (Vision, on-device)

    static func analyze(_ input: PhotoInput) -> PhotoInfo {
        var aspect = 1.5
        var focus: CGPoint?
        var color = SIMD3<Double>(0.5, 0.5, 0.5)
        var date = (try? input.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(timeIntervalSince1970: 0)

        if let src = CGImageSourceCreateWithURL(input.url as CFURL, nil) {
            if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                if let d = f.date(from: text) { date = d }
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: !Renderer.isRAW(input.url),
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
            ]
            if let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary), thumb.height > 0 {
                aspect = Double(thumb.width) / Double(thumb.height)
                focus = subjectCenter(in: thumb)
                color = averageColor(of: thumb)
            }
        }
        return PhotoInfo(input: input, aspect: aspect, focus: focus, date: date, color: color)
    }

    /// Center of the faces if there are any, otherwise of the most salient objects.
    private static func subjectCenter(in image: CGImage) -> CGPoint? {
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([faces, saliency])

        var boxes = (faces.results ?? []).map(\.boundingBox)
        if boxes.isEmpty, let objects = saliency.results?.first?.salientObjects { boxes = objects.map(\.boundingBox) }
        guard var union = boxes.first else { return nil }
        for b in boxes.dropFirst() { union = union.union(b) }
        // A box covering nearly everything says nothing about where to crop.
        if union.width * union.height > 0.85 { return nil }
        return CGPoint(x: union.midX, y: union.midY)
    }

    private static func averageColor(of image: CGImage) -> SIMD3<Double> {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return SIMD3(0.5, 0.5, 0.5) }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return SIMD3(Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }

    // MARK: Ordering

    static func order(_ infos: [PhotoInfo], by mode: MontageOrder) -> [Int] {
        let all = Array(infos.indices)
        switch mode {
        case .listed:
            return all
        case .captured:
            return all.sorted { (infos[$0].date, $0) < (infos[$1].date, $1) }
        case .color:
            // Greedy walk: from each photo, go to the most similar remaining one.
            guard !all.isEmpty else { return [] }
            var remaining = Set(all)
            var current = 0
            var out = [0]
            remaining.remove(0)
            while !remaining.isEmpty {
                let c = infos[current].color
                let next = remaining.min { simd_distance(infos[$0].color, c) < simd_distance(infos[$1].color, c) }!
                out.append(next)
                remaining.remove(next)
                current = next
            }
            return out
        }
    }

    // MARK: Layout planning

    /// 0 when a photo fits its slot without cropping, towards 1 as more of it gets cropped away.
    private static func cropLoss(aspect: Double, slot: CGRect) -> Double {
        let s = Double(slot.width / slot.height)
        return 1 - min(aspect / s, s / aspect)
    }

    /// Best way to hand `photos` to the layout's slots (a photo can sit in any slot of its own frame).
    private static func bestAssignment(layout: MontageLayout, photos: [Int], infos: [PhotoInfo],
                                       slots: [CGRect]) -> (loss: Double, order: [Int]) {
        var best = (loss: Double.infinity, order: photos)
        func permute(_ chosen: [Int], _ rest: [Int]) {
            if rest.isEmpty {
                let loss = zip(chosen, slots).reduce(0.0) { $0 + cropLoss(aspect: infos[$1.0].aspect, slot: $1.1) } / Double(slots.count)
                if loss < best.loss { best = (loss, chosen) }
                return
            }
            for (i, p) in rest.enumerated() {
                var r = rest; r.remove(at: i)
                permute(chosen + [p], r)
            }
        }
        permute([], photos)
        return best
    }

    /// Chunks the ordered photos into frames. In Auto mode each frame takes whichever layout crops the
    /// next few photos the least, with a nudge to vary layouts from frame to frame.
    static func plan(order: [Int], infos: [PhotoInfo], mode: MontageLayoutMode, canvas: CGSize, gap: CGFloat) -> [MontageScene] {
        var scenes: [MontageScene] = []
        var i = 0
        while i < order.count {
            let remaining = order.count - i
            var candidates: [MontageLayout]
            switch mode {
            case .auto: candidates = [.stack2, .stack3, .hero2, .grid4]
            case .two: candidates = [.stack2]
            case .three: candidates = [.stack3, .hero2]
            case .four: candidates = [.grid4]
            }
            candidates = candidates.filter { $0.count <= remaining }
            if candidates.isEmpty {
                candidates = remaining == 1 ? [.single] : (remaining == 2 ? [.stack2] : [.stack3, .hero2])
            }

            var best: (score: Double, scene: MontageScene)?
            for layout in candidates {
                let photos = Array(order[i..<(i + layout.count)])
                let fit = bestAssignment(layout: layout, photos: photos, infos: infos, slots: layout.slots(canvas: canvas, gap: gap))
                var score = fit.loss
                if mode == .auto {
                    if scenes.last?.layout == layout { score += 0.08 }
                    if scenes.count >= 2, scenes[scenes.count - 2].layout == layout { score += 0.04 }
                }
                if best == nil || score < best!.score { best = (score, MontageScene(layout: layout, photos: fit.order)) }
            }
            let scene = best!.scene
            scenes.append(scene)
            i += scene.layout.count
        }
        return scenes
    }

    // MARK: Compositing

    /// A photo with the global look and its own fix applied, at a size suited to the target.
    static func gradedImage(_ info: PhotoInfo, look: Look, raw: RawSettings, maxDimension: Int) -> CIImage? {
        let url = info.input.url
        var photoLook = look
        let source: CIImage?
        if Renderer.isRAW(url), let preview = RAWPreview(url: url, maxDimension: maxDimension) {
            source = preview.develop(raw.adding(info.input.fix))
        } else {
            source = Renderer.loadPreviewSource(url: url, maxDimension: maxDimension)
            photoLook.fix = info.input.fix
        }
        guard let source else { return nil }
        return Renderer.shared.apply(photoLook, to: source)
    }

    /// Scales the photo to cover the slot, crops around the subject, and moves it into place.
    /// `slot` uses a top-left origin; the result is in Core Image's bottom-left coordinates.
    private static func place(_ image: CIImage, in slot: CGRect, canvasHeight: CGFloat, focus: CGPoint?) -> CIImage {
        let w = image.extent.width, h = image.extent.height
        let scale = max(slot.width / w, slot.height / h)

        var scaled: CIImage
        if scale < 1 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image
            f.scale = Float(scale)
            f.aspectRatio = 1
            scaled = f.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let sw = scaled.extent.width, sh = scaled.extent.height

        let center = focus ?? CGPoint(x: 0.5, y: 0.5)
        let ox = max(0, min(sw - slot.width, center.x * sw - slot.width / 2)).rounded() + scaled.extent.minX
        let oy = max(0, min(sh - slot.height, center.y * sh - slot.height / 2)).rounded() + scaled.extent.minY
        let crop = CGRect(x: ox, y: oy, width: slot.width, height: slot.height)

        let destX = slot.minX, destY = canvasHeight - slot.minY - slot.height
        return scaled.cropped(to: crop).transformed(by: CGAffineTransform(translationX: destX - ox, y: destY - oy))
    }

    static func composeScene(_ scene: MontageScene, infos: [PhotoInfo], look: Look, raw: RawSettings,
                             canvas: CGSize, gap: CGFloat, maxDimension: Int) -> CIImage {
        var out = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: canvas))
        for (slot, index) in zip(scene.layout.slots(canvas: canvas, gap: gap), scene.photos) {
            let info = infos[index]
            guard let graded = gradedImage(info, look: look, raw: raw, maxDimension: maxDimension) else { continue }
            out = place(graded, in: slot, canvasHeight: canvas.height, focus: info.focus).composited(over: out)
        }
        return out
    }
}
