import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

extension MontageVideo {
    /// One shared context for previews and scene bakes (they all work in sRGB).
    static let sharedContext = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
}

@MainActor
final class MontageModel: ObservableObject {
    // Frames
    @Published var layoutMode = MontageLayoutMode.auto { didSet { replan() } }
    @Published var order = MontageOrder.listed { didSet { replan() } }
    @Published var gap = 6.0 { didSet { renderPreview() } }

    // Tempo and music
    @Published var bpm = 120.0
    @Published var beatsPerCut = 4
    @Published var musicURL: URL?
    @Published var musicOffset = 0.0

    // Look of the video
    @Published var transition = MontageTransition.fade
    @Published var quality = MontageQuality.full

    // State
    @Published private(set) var scenes: [MontageScene] = []
    @Published var previewIndex = 0 { didSet { renderPreview() } }
    @Published var previewImage: NSImage?
    @Published var analyzing = false
    @Published var detecting = false
    @Published var progress: Double?
    @Published var status: String?

    private var infos: [PhotoInfo] = []
    private var look = Look.original
    private var raw = RawSettings()
    private var tapTimes: [TimeInterval] = []
    private var previewTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var cancelFlag: CancelFlag?

    /// Plans are laid out on a 1080 x 1920 reference canvas whatever the output size.
    private let referenceCanvas = CGSize(width: 1080, height: 1920)

    var sceneDuration: Double { Tempo.sceneDuration(bpm: bpm, beatsPerCut: beatsPerCut) }
    var totalDuration: Double { Double(scenes.count) * sceneDuration }
    var isRendering: Bool { progress != nil }
    var previewCaption: String {
        guard scenes.indices.contains(previewIndex) else { return "" }
        return "Scene \(previewIndex + 1) of \(scenes.count) · \(scenes[previewIndex].layout.name)"
    }

    // MARK: Opening

    func open(photos: [PhotoInput], look: Look, raw: RawSettings) {
        self.look = look
        self.raw = raw
        infos = []
        scenes = []
        previewImage = nil
        status = nil
        previewIndex = 0
        analyzing = true

        Task {
            // One photo at a time: running Vision on several photos in parallel deadlocks.
            let analyzed = await Task.detached(priority: .userInitiated) { () -> [PhotoInfo] in
                photos.map { MontageEngine.analyze($0) }
            }.value
            infos = analyzed
            analyzing = false
            replan()
        }
    }

    private func replan() {
        guard !infos.isEmpty else { return }
        let ordered = MontageEngine.order(infos, by: order)
        scenes = MontageEngine.plan(order: ordered, infos: infos, mode: layoutMode, canvas: referenceCanvas, gap: CGFloat(gap))
        previewIndex = min(previewIndex, max(0, scenes.count - 1))
        renderPreview()
    }

    private func renderPreview() {
        guard scenes.indices.contains(previewIndex) else { previewImage = nil; return }
        let scene = scenes[previewIndex]
        let infos = self.infos, look = self.look, raw = self.raw, gap = CGFloat(self.gap) / 2
        previewTask?.cancel()
        previewTask = Task {
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let canvas = CGSize(width: 540, height: 960)
                let composed = MontageEngine.composeScene(scene, infos: infos, look: look, raw: raw, canvas: canvas, gap: gap, maxDimension: 1100)
                return MontageVideo.sharedContext.createCGImage(composed, from: CGRect(origin: .zero, size: canvas),
                                                                format: .RGBA8, colorSpace: MontageVideo.colorSpace)
            }.value
            guard !Task.isCancelled, let image else { return }
            previewImage = NSImage(cgImage: image, size: .zero)
        }
    }

    // MARK: Tempo

    func tap() {
        let now = Date.timeIntervalSinceReferenceDate
        if let last = tapTimes.last, now - last > 2 { tapTimes = [] }
        tapTimes.append(now)
        if let tapped = Tempo.bpm(fromTaps: tapTimes) { bpm = (tapped * 10).rounded() / 10 }
    }

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a music track"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        musicURL = url
        musicOffset = 0
        status = nil
    }

    func removeMusic() {
        musicURL = nil
        musicOffset = 0
    }

    func detectTempo() {
        guard let url = musicURL, !detecting else { return }
        detecting = true
        status = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { BeatDetector.detect(url: url) }.value
            detecting = false
            guard let result else {
                status = "Couldn't find a clear beat in that track. Set the BPM by hand or tap it."
                return
            }
            bpm = min(180, max(60, result.bpm))
            musicOffset = result.firstBeat
            status = String(format: "Detected about %.1f BPM, first beat at %.2fs. Check it by ear and fine-tune with Tap or the slider.",
                            result.bpm, result.firstBeat)
        }
    }

    // MARK: Rendering

    func cancelRender() { cancelFlag?.set() }

    func render() {
        guard !scenes.isEmpty, !isRendering else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Marmalade Montage.mp4"
        panel.message = "Save the montage video"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let scenes = self.scenes, infos = self.infos, look = self.look, raw = self.raw
        let size = quality.size
        let scaledGap = CGFloat(gap) * size.width / referenceCanvas.width
        let duration = sceneDuration, transition = self.transition
        let music = musicURL.map { MontageVideo.Music(url: $0, offset: musicOffset) }
        let flag = CancelFlag()
        cancelFlag = flag
        progress = 0
        status = nil

        renderTask = Task {
            do {
                let baked = try await Task.detached(priority: .userInitiated) { () -> [CIImage] in
                    var images: [CIImage] = []
                    for (i, scene) in scenes.enumerated() {
                        if flag.isSet { throw MontageVideoError.cancelled }
                        let composed = MontageEngine.composeScene(scene, infos: infos, look: look, raw: raw, canvas: size, gap: scaledGap, maxDimension: 2400)
                        guard let image = MontageVideo.rasterize(composed, size: size, context: MontageVideo.sharedContext) else {
                            throw MontageVideoError.writer("A frame couldn't be rendered.")
                        }
                        images.append(image)
                        let done = Double(i + 1) / Double(scenes.count)
                        await MainActor.run { self.progress = done * 0.3 }
                    }
                    return images
                }.value

                try await MontageVideo.write(scenes: baked, sceneDuration: duration, transition: transition, size: size,
                                             music: music, to: url,
                                             progress: { p in Task { @MainActor in self.progress = 0.3 + 0.7 * p } },
                                             cancel: flag)
                progress = nil
                status = "Saved \(url.lastPathComponent) (\(String(format: "%.0f", Double(scenes.count) * duration))s)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch MontageVideoError.cancelled {
                progress = nil
                status = "Cancelled."
            } catch {
                progress = nil
                status = "Render failed: \(error.localizedDescription)"
            }
        }
    }
}
