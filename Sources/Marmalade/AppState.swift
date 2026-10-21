import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

struct Photo: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumbnail: NSImage?
    var fix = PhotoFix()
    var name: String { url.lastPathComponent }
}

@MainActor
final class AppState: ObservableObject {
    // Library
    @Published var photos: [Photo] = []
    @Published var selectedID: Photo.ID? { didSet { loadSelectedSource() } }

    // Look
    @Published var adjustments = Adjustments.startingPoint { didSet { refresh() } }
    @Published var luts: [LUT] = [] { didSet { refreshLUTThumbs() } }
    @Published var lutThumbs: [LUT.ID: NSImage] = [:]
    @Published var lutFilter = ""

    // Slices (saved looks)
    @Published var slices: [LookSlice] = [] { didSet { saveSlices(); refreshSliceThumbs() } }
    @Published var sliceThumbs: [LookSlice.ID: NSImage] = [:]
    @Published var selectedLUTID: LUT.ID? { didSet { refresh() } }
    @Published var lutIntensity = 1.0 { didSet { refresh() } }
    @Published var showOriginal = false { didSet { refresh() } }

    // RAW + output
    @Published var rawSettings = RawSettings() { didSet { redevelopRAW() } }
    @Published var outputSpace = OutputSpace.matchSource { didSet { refresh() } }
    @Published var selectedIsRAW = false

    // Output
    @Published var preview: NSImage?
    @Published var jpegQuality = 0.95
    @Published var exportProgress: Double?
    @Published var message: String?
    @Published var dropTargeted = false

    private var source: CIImage?
    private var renderTask: Task<Void, Never>?
    private var rawPreview: RAWPreview?
    private var rawTask: Task<Void, Never>?
    private var thumbDebounce: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?
    private var sliceThumbTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic"]

    private static let lutFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Marmalade/LUTs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let slicesFile: URL = lutFolder.deletingLastPathComponent().appendingPathComponent("Slices.json")

    init() {
        loadSavedLUTs()
        loadSlices()
    }

    /// The selected photo's own exposure / white balance (separate from the global look).
    var selectedFix: PhotoFix {
        get { photos.first { $0.id == selectedID }?.fix ?? PhotoFix() }
        set {
            guard let i = photos.firstIndex(where: { $0.id == selectedID }) else { return }
            photos[i].fix = newValue
            if selectedIsRAW { redevelopRAW() } else { refresh() }
        }
    }

    var selectedPhotoName: String? { photos.first { $0.id == selectedID }?.name }

    var selectedLUT: LUT? { luts.first { $0.id == selectedLUTID } }

    var currentLook: Look {
        Look(adjustments: adjustments, lut: selectedLUT, lutIntensity: lutIntensity)
    }

    // MARK: Adding things

    func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.ingest([url]) }
            }
        }
    }

    func addPhotosPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Choose photos or folders"
        if panel.runModal() == .OK { ingest(panel.urls) }
    }

    func addLUTPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.message = "Choose .cube LUT files"
        if panel.runModal() == .OK { ingest(panel.urls) }
    }

    func ingest(_ urls: [URL]) {
        var imageURLs: [URL] = []
        var lutURLs: [URL] = []

        func classify(_ url: URL) {
            let ext = url.pathExtension.lowercased()
            if ext == "cube" { lutURLs.append(url) }
            else if Self.imageExtensions.contains(ext) || Renderer.isRAW(url) { imageURLs.append(url) }
        }

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                (walker?.allObjects as? [URL])?.sorted { $0.path < $1.path }.forEach(classify)
            } else {
                classify(url)
            }
        }

        addPhotos(imageURLs)
        lutURLs.forEach(importLUT)
    }

    private func addPhotos(_ urls: [URL]) {
        let existing = Set(photos.map(\.url))
        let new = urls.filter { !existing.contains($0) }.map { Photo(url: $0) }
        guard !new.isEmpty else { return }
        photos.append(contentsOf: new)
        if selectedID == nil { selectedID = new.first?.id }

        for photo in new {
            Task {
                let thumb = await Task.detached(priority: .utility) { Self.makeThumbnail(photo.url) }.value
                if let i = photos.firstIndex(where: { $0.id == photo.id }) { photos[i].thumbnail = thumb }
            }
        }
    }

    nonisolated private static func makeThumbnail(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // RAW: use the camera's embedded preview instead of developing the whole file for a thumbnail.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: !Renderer.isRAW(url),
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    func remove(_ ids: Set<Photo.ID>) {
        photos.removeAll { ids.contains($0.id) }
        if let id = selectedID, ids.contains(id) { selectedID = photos.first?.id }
    }

    func moveSelection(_ delta: Int) {
        guard !photos.isEmpty else { return }
        let current = photos.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : photos.count)
        selectedID = photos[max(0, min(photos.count - 1, current + delta))].id
    }

    func clearPhotos() {
        photos = []
        selectedID = nil
    }

    // MARK: LUTs

    private func loadSavedLUTs() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.lutFolder, includingPropertiesForKeys: nil)) ?? []
        let cubes = files.filter { $0.pathExtension.lowercased() == "cube" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        Task {
            let loaded = await Task.detached { cubes.compactMap { try? LUT(url: $0) } }.value
            luts.append(contentsOf: loaded)
        }
    }

    private func importLUT(_ url: URL) {
        let dest = Self.lutFolder.appendingPathComponent(url.lastPathComponent)
        Task {
            do {
                let lut = try await Task.detached { () -> LUT in
                    if url.standardizedFileURL != dest.standardizedFileURL {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.copyItem(at: url, to: dest)
                    }
                    do { return try LUT(url: dest) }
                    catch { try? FileManager.default.removeItem(at: dest); throw error }
                }.value
                luts.removeAll { $0.url == dest }
                luts.append(lut)
                luts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                selectedLUTID = lut.id
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func removeSelectedLUT() {
        if let lut = selectedLUT { remove(lut) }
    }

    func remove(_ lut: LUT) {
        try? FileManager.default.removeItem(at: lut.url)
        luts.removeAll { $0.id == lut.id }
        if selectedLUTID == lut.id { selectedLUTID = nil }
    }

    func revealLUTLibrary() {
        NSWorkspace.shared.open(Self.lutFolder)
    }

    var filteredLUTs: [LUT] {
        let q = lutFilter.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? luts : luts.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    // MARK: Slices

    private var loadingSlices = false

    private func loadSlices() {
        loadingSlices = true
        defer { loadingSlices = false }
        if let data = try? Data(contentsOf: Self.slicesFile),
           let saved = try? JSONDecoder().decode([LookSlice].self, from: data) {
            slices = saved
        } else if !FileManager.default.fileExists(atPath: Self.slicesFile.path) {
            loadingSlices = false      // first launch: write the starter Slices to disk
            slices = LookSlice.starters
        }
    }

    private func saveSlices() {
        guard !loadingSlices else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(slices) { try? data.write(to: Self.slicesFile, options: .atomic) }
    }

    private func libraryLUT(named name: String?) -> LUT? {
        guard let name else { return nil }
        return luts.first { $0.name == name }
    }

    /// The slice whose settings match what's on the sliders right now, if any.
    var activeSliceID: LookSlice.ID? {
        (slices + FilmStocks.all).first {
            $0.adjustments == adjustments
                && $0.lutName == selectedLUT?.name
                && (selectedLUT == nil || $0.lutIntensity == lutIntensity)
        }?.id
    }

    private func askForName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    func newSlice() {
        guard let name = askForName(title: "Name this Slice", initial: "") else { return }
        slices.append(LookSlice(name: name, adjustments: adjustments, lutName: selectedLUT?.name, lutIntensity: lutIntensity))
        message = "Saved Slice “\(name)”."
    }

    func apply(_ slice: LookSlice) {
        adjustments = slice.adjustments
        lutIntensity = slice.lutIntensity
        if let name = slice.lutName {
            if let lut = libraryLUT(named: name) {
                selectedLUTID = lut.id
            } else {
                selectedLUTID = nil
                message = "Slice “\(slice.name)” uses the LUT “\(name)”, which isn't in your library. Add it and apply the Slice again."
            }
        } else {
            selectedLUTID = nil
        }
    }

    func updateSlice(_ slice: LookSlice) {
        guard let i = slices.firstIndex(where: { $0.id == slice.id }) else { return }
        slices[i].adjustments = adjustments
        slices[i].lutName = selectedLUT?.name
        slices[i].lutIntensity = lutIntensity
        message = "Updated Slice “\(slice.name)”."
    }

    func renameSlice(_ slice: LookSlice) {
        guard let i = slices.firstIndex(where: { $0.id == slice.id }),
              let name = askForName(title: "Rename Slice", initial: slice.name) else { return }
        slices[i].name = name
    }

    /// Copies a built-in film stock into your own Slices so you can tweak and keep it.
    func saveStockAsSlice(_ stock: LookSlice) {
        guard let name = askForName(title: "Save as your own Slice", initial: stock.name) else { return }
        slices.append(LookSlice(name: name, adjustments: stock.adjustments, lutName: nil))
        message = "Saved Slice “\(name)”."
    }

    func deleteSlice(_ slice: LookSlice) {
        slices.removeAll { $0.id == slice.id }
    }

    private func refreshSliceThumbs() {
        sliceThumbTask?.cancel()
        guard let source else { sliceThumbs = [:]; return }
        let items = (slices + FilmStocks.all).map { ($0.id, Look(adjustments: $0.adjustments, lut: libraryLUT(named: $0.lutName), lutIntensity: $0.lutIntensity)) }
        let tiny = source.transformed(by: CGAffineTransform(scaleX: 200 / source.extent.width, y: 200 / source.extent.width))
        sliceThumbTask = Task {
            let rendered = await Task.detached(priority: .utility) { () -> [(LookSlice.ID, CGImage)] in
                items.compactMap { id, look in
                    Renderer.shared.renderPreview(source: tiny, look: look).map { (id, $0) }
                }
            }.value
            guard !Task.isCancelled else { return }
            sliceThumbs = Dictionary(uniqueKeysWithValues: rendered.map { ($0.0, NSImage(cgImage: $0.1, size: .zero)) })
        }
    }

    /// Tiny renders of the current photo through each LUT, for browsing the library.
    private func refreshLUTThumbs() {
        thumbTask?.cancel()
        guard let source, !luts.isEmpty else { lutThumbs = [:]; return }
        let all = self.luts
        let tiny = source.transformed(by: CGAffineTransform(scaleX: 160 / source.extent.width, y: 160 / source.extent.width))
        thumbTask = Task {
            let rendered = await Task.detached(priority: .utility) { () -> [(LUT.ID, CGImage)] in
                all.compactMap { lut in
                    let look = Look(adjustments: .neutral, lut: lut, lutIntensity: 1)
                    return Renderer.shared.renderPreview(source: tiny, look: look).map { (lut.id, $0) }
                }
            }.value
            guard !Task.isCancelled else { return }
            lutThumbs = Dictionary(uniqueKeysWithValues: rendered.map { ($0.0, NSImage(cgImage: $0.1, size: .zero)) })
        }
    }

    // MARK: Preview

    var hasRAW: Bool { photos.contains { Renderer.isRAW($0.url) } }

    private func loadSelectedSource() {
        guard let photo = photos.first(where: { $0.id == selectedID }) else {
            source = nil
            rawPreview = nil
            selectedIsRAW = false
            preview = nil
            lutThumbs = [:]
            sliceThumbs = [:]
            return
        }
        let url = photo.url
        let settings = rawSettings.adding(photo.fix)
        selectedIsRAW = Renderer.isRAW(url)
        rawPreview = nil
        rawTask?.cancel()
        renderTask?.cancel()
        renderTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (CIImage?, RAWPreview?) in
                if Renderer.isRAW(url), let raw = RAWPreview(url: url, maxDimension: 2400) {
                    return (raw.develop(settings), raw)
                }
                return (Renderer.loadPreviewSource(url: url, maxDimension: 2400), nil)
            }.value
            guard !Task.isCancelled else { return }
            rawPreview = result.1
            source = result.0
            refresh()
            refreshLUTThumbs()
            refreshSliceThumbs()
        }
    }

    /// RAW sliders: re-develop the open RAW file (cheap) instead of reloading it.
    private func redevelopRAW() {
        guard let rawPreview else { return }
        let settings = rawSettings.adding(selectedFix)
        rawTask?.cancel()
        rawTask = Task {
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) { rawPreview.develop(settings) }.value
            guard !Task.isCancelled, let image else { return }
            source = image
            refresh()
            thumbDebounce?.cancel()
            thumbDebounce = Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                refreshLUTThumbs()
                refreshSliceThumbs()
            }
        }
    }

    private func refresh() {
        guard let source else { return }
        var look = showOriginal ? Look.original : currentLook
        if !showOriginal && !selectedIsRAW { look.fix = selectedFix }
        let space = outputSpace
        renderTask?.cancel()
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 15_000_000)
            guard !Task.isCancelled else { return }
            let cg = await Task.detached(priority: .userInitiated) {
                Renderer.shared.renderPreview(source: source, look: look, output: space)
            }.value
            guard !Task.isCancelled, let cg else { return }
            preview = NSImage(cgImage: cg, size: .zero)
        }
    }

    // MARK: Export

    var isExporting: Bool { exportProgress != nil }

    func cancelExport() { exportTask?.cancel() }

    func exportAll() {
        guard !photos.isEmpty else { return }
        let look = currentLook

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the finished photos"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let items = photos.map { ($0.url, $0.fix) }
        let quality = jpegQuality
        let raw = rawSettings
        let space = outputSpace
        message = nil
        exportProgress = 0

        exportTask = Task {
            var done = 0
            var failed: [String] = []
            for (url, fix) in items {
                if Task.isCancelled { break }
                let dest = Self.uniqueDestination(for: url, in: folder)
                // RAW: the fix becomes true RAW exposure / white balance. Everything else: linear-light gains.
                var photoLook = look
                var photoRaw = raw
                if Renderer.isRAW(url) { photoRaw = raw.adding(fix) } else { photoLook.fix = fix }
                let finalLook = photoLook, finalRaw = photoRaw
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try Renderer.shared.export(from: url, to: dest, look: finalLook, quality: quality, raw: finalRaw, output: space)
                    }.value
                    done += 1
                } catch {
                    failed.append(url.lastPathComponent)
                }
                exportProgress = Double(done + failed.count) / Double(items.count)
            }
            exportProgress = nil
            var text = "Exported \(done) of \(items.count) to \(folder.lastPathComponent)."
            if Task.isCancelled { text = "Cancelled after \(done) of \(items.count)." }
            if !failed.isEmpty { text += " Failed: \(failed.joined(separator: ", "))" }
            message = text
            if done > 0 { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
    }

    /// Never overwrites anything: "IMG.jpg", then "IMG 2.jpg", "IMG 3.jpg", ...
    nonisolated private static func uniqueDestination(for source: URL, in folder: URL) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(base).appendingPathExtension("jpg")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension("jpg")
            n += 1
        }
        return candidate
    }
}
