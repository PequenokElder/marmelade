import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState

    // @State is a macro the Command Line Tools toolchain can't expand, so this lives on AppState.
    private var dropTargeted: Binding<Bool> { $app.dropTargeted }

    var body: some View {
        ZStack {
            FrostedBackdrop()
            HStack(spacing: 12) {
                PhotoListView()
                    .frame(width: 252)
                    .modifier(GlassPanel())
                PreviewView()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
                ControlsView()
                    .frame(width: 316)
                    .modifier(GlassPanel())
            }
            .padding(.init(top: 30, leading: 12, bottom: 12, trailing: 12))
        }
        .preferredColorScheme(.dark)
        .tint(Theme.orange)
        .frame(minWidth: 1080, minHeight: 720)
        .onDrop(of: [.fileURL], isTargeted: dropTargeted) { providers in
            app.handleDrop(providers)
            return true
        }
        .overlay {
            if app.dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.orange, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Photo list

struct PhotoListView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(app.photos) { photo in
                            row(photo).id(photo.id)
                        }
                    }
                    .padding(8)
                }
                .focusable()
                .modifier(NoFocusRing())
                .onMoveCommand { direction in
                    app.moveSelection(direction == .up || direction == .left ? -1 : 1)
                }
                .onDeleteCommand {
                    if let id = app.selectedID { app.remove([id]) }
                }
                .onChange(of: app.selectedID) { id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }

            ThisPhotoView()

            HStack {
                Button("Add…") { app.addPhotosPanel() }
                Spacer()
                Text("\(app.photos.count) photo\(app.photos.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear") { app.clearPhotos() }
                    .disabled(app.photos.isEmpty)
            }
        }
        .padding(10)
    }

    private func row(_ photo: Photo) -> some View {
        let selected = photo.id == app.selectedID
        return HStack(spacing: 8) {
            Group {
                if let thumb = photo.thumbnail {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 56, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(photo.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !photo.fix.isNeutral {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption2).foregroundStyle(Theme.teal)
                    .help("This photo has its own adjustments")
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.orange.opacity(0.30) : Color.white.opacity(0.0001)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.orange.opacity(0.85) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { app.selectedID = photo.id }
        .contextMenu {
            Button("Remove from list") { app.remove([photo.id]) }
        }
    }
}

// MARK: - This photo

/// Exposure and white balance for just the selected photo, kept apart from the global look.
struct ThisPhotoView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("This photo")
                Spacer()
                Button("Reset") { app.selectedFix = PhotoFix() }
                    .buttonStyle(TealLinkStyle()).font(.caption)
                    .disabled(app.selectedFix.isNeutral)
            }
            if let name = app.selectedPhotoName {
                Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                AdjustmentSlider(title: "Exposure (EV)", value: $app.selectedFix.exposure, range: -3...3, neutral: 0, format: "%+.2f")
                AdjustmentSlider(title: "Temperature", value: $app.selectedFix.temperature, range: -1...1, neutral: 0, format: "%+.2f")
                AdjustmentSlider(title: "Tint", value: $app.selectedFix.tint, range: -1...1, neutral: 0, format: "%+.2f")
                Text(app.selectedIsRAW
                     ? "RAW: true exposure and white balance. Applied on top of the global look."
                     : "Applied before the global look, in linear light.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Select a photo to adjust it on its own.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .modifier(GlassCard())
    }
}

// MARK: - Preview

struct PreviewView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            Color(white: 0.085)

            if app.photos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 52))
                        .foregroundStyle(Theme.gradient)
                    Text("Drop photos or folders here")
                        .font(.title3)
                    Text("Drop .cube files to add LUTs")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            } else if let image = app.preview {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .topTrailing) {
            if !app.photos.isEmpty {
                Toggle("Show original", isOn: $app.showOriginal)
                    .toggleStyle(.button)
                    .keyboardShortcut("\\", modifiers: [])
                    .padding(12)
            }
        }
    }
}

// MARK: - Controls

struct ControlsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    slicesSection.modifier(GlassCard())
                    filmStocksSection.modifier(GlassCard())
                    if app.hasRAW { rawSection.modifier(GlassCard()) }
                    enhanceSection.modifier(GlassCard())
                    safeguardSection.modifier(GlassCard())
                    filmSection.modifier(GlassCard())
                    grainSection.modifier(GlassCard())
                    lutSection.modifier(GlassCard())
                }
                .padding(12)
            }
            exportControls
                .modifier(GlassCard())
                .padding(12)
        }
    }

    private func header(_ title: String, reset: (() -> Void)? = nil) -> some View {
        HStack {
            SectionTitle(title)
            Spacer()
            if let reset { Button("Reset", action: reset).buttonStyle(TealLinkStyle()).font(.caption).tint(Theme.teal) }
        }
    }

    private var slicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Slices")
                Spacer()
                Button("New Slice…") { app.newSlice() }
                    .buttonStyle(TealLinkStyle()).font(.caption).tint(Theme.teal)
            }

            if app.slices.isEmpty {
                Text("A Slice saves your whole look: every slider plus the LUT. Dial something in, then tap New Slice.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let active = app.activeSliceID
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(app.slices) { slice in
                            sliceCard(slice, isActive: slice.id == active)
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 220)
                Text("Click to apply. Right-click to update, rename or delete.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var filmStocksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Film stocks")
            let active = app.activeSliceID
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(FilmStocks.all) { stock in
                    sliceCard(stock, isActive: stock.id == active, isStock: true)
                }
            }
            .padding(2)
            Text("Hand-tuned approximations of each film's character, not exact profiles. Click one, then fine-tune or save it as your own Slice (right-click).")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sliceCard(_ slice: LookSlice, isActive: Bool, isStock: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let thumb = app.sliceThumbs[slice.id] {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 62)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            HStack(spacing: 4) {
                Text(slice.name).font(.caption).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if slice.lutName != nil {
                    Image(systemName: "cube").font(.caption2).foregroundStyle(.secondary)
                        .help("Includes LUT: \(slice.lutName ?? "")")
                }
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 8).fill(isActive ? Theme.orange.opacity(0.28) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isActive ? Theme.orange : Color.white.opacity(0.16), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { app.apply(slice) }
        .contextMenu {
            if isStock {
                Button("Save as my own Slice…") { app.saveStockAsSlice(slice) }
            } else {
                Button("Update with current settings") { app.updateSlice(slice) }
                Button("Rename…") { app.renameSlice(slice) }
                Divider()
                Button("Delete", role: .destructive) { app.deleteSlice(slice) }
            }
        }
    }

    private var rawSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("RAW development") { app.rawSettings = RawSettings() }
            let d = RawSettings()
            AdjustmentSlider(title: "Temperature (cool – warm)", value: $app.rawSettings.temperature, range: -1...1, neutral: d.temperature, format: "%+.2f")
            AdjustmentSlider(title: "Tint (green – magenta)", value: $app.rawSettings.tint, range: -1...1, neutral: d.tint, format: "%+.2f")
            AdjustmentSlider(title: "Exposure (EV)", value: $app.rawSettings.exposure, range: -3...3, neutral: d.exposure, format: "%+.2f")
            AdjustmentSlider(title: "Tone boost", value: $app.rawSettings.toneBoost, range: 0...1, neutral: d.toneBoost, format: "%.0f%%", scale: 100)
            AdjustmentSlider(title: "Shadows", value: $app.rawSettings.shadows, range: -1...1, neutral: d.shadows, format: "%+.2f")
            AdjustmentSlider(title: "Sharpness", value: $app.rawSettings.sharpness, range: 0...1, neutral: d.sharpness, format: "%.0f%%", scale: 100)
            Text(app.selectedIsRAW
                 ? "White balance starts from the camera's setting. Lower Tone boost for a flatter starting image."
                 : "The selected photo isn't RAW, so these don't change it. They apply to every RAW file when you export.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var enhanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Enhance") {
                let d = Adjustments.startingPoint
                app.adjustments.exposure = d.exposure
                app.adjustments.contrast = d.contrast
                app.adjustments.saturation = d.saturation
                app.adjustments.vibrance = d.vibrance
                app.adjustments.warmth = d.warmth
                app.adjustments.tint = d.tint
            }
            let d = Adjustments.startingPoint
            AdjustmentSlider(title: "Exposure", value: $app.adjustments.exposure, range: -1...1, neutral: d.exposure, format: "%+.2f")
            AdjustmentSlider(title: "Contrast", value: $app.adjustments.contrast, range: 0.6...1.5, neutral: d.contrast, format: "%.2f")
            AdjustmentSlider(title: "Saturation", value: $app.adjustments.saturation, range: 0...2, neutral: d.saturation, format: "%.2f")
            AdjustmentSlider(title: "Vibrance", value: $app.adjustments.vibrance, range: -1...1, neutral: d.vibrance, format: "%+.2f")
            AdjustmentSlider(title: "Warmth", value: $app.adjustments.warmth, range: -1...1, neutral: d.warmth, format: "%+.2f")
            AdjustmentSlider(title: "Tint (green – magenta)", value: $app.adjustments.tint, range: -1...1, neutral: d.tint, format: "%+.2f")
            Text("Double-click a label to reset it.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var safeguardSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Safeguards")
            AdjustmentSlider(title: "Color limit", value: $app.adjustments.colorLimit, range: 0.6...1, neutral: Adjustments.startingPoint.colorLimit, format: "%.2f")
            Text("Boosted colors ease toward this ceiling instead of slamming into pure, flat color. Lower is safer.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AdjustmentSlider(title: "Color noise reduction", value: $app.adjustments.colorNoise, range: 0...1, neutral: Adjustments.startingPoint.colorNoise, format: "%.0f%%", scale: 100)
            Text("Smooths blotchy or blocky color (JPEG chroma artifacts) before contrast and saturation amplify it. Brightness detail is untouched.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Protect skin tones", isOn: $app.adjustments.protectSkin).toggleStyle(.switch)
            Toggle("Anti-banding dither", isOn: $app.adjustments.antiBanding).toggleStyle(.switch)
            Text("Contrast, exposure and warmth use curves that never clip pure black or white.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var filmSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Film look") {
                let d = Adjustments.startingPoint
                app.adjustments.rolloff = d.rolloff
                app.adjustments.coolShadows = d.coolShadows
                app.adjustments.highlightWarmth = d.highlightWarmth
                app.adjustments.bloom = d.bloom
                app.adjustments.halation = d.halation
                app.adjustments.glowThreshold = d.glowThreshold
                app.adjustments.vignette = d.vignette
            }
            let d = Adjustments.startingPoint
            AdjustmentSlider(title: "Rolloff", value: $app.adjustments.rolloff, range: 0...1, neutral: d.rolloff, format: "%.0f%%", scale: 100)
            AdjustmentSlider(title: "Shadows (warm – cool)", value: $app.adjustments.coolShadows, range: -1...1, neutral: d.coolShadows, format: "%+.0f%%", scale: 100)
            AdjustmentSlider(title: "Highlights (cool – warm)", value: $app.adjustments.highlightWarmth, range: -1...1, neutral: d.highlightWarmth, format: "%+.0f%%", scale: 100)
            AdjustmentSlider(title: "Bloom", value: $app.adjustments.bloom, range: 0...1, neutral: d.bloom, format: "%.0f%%", scale: 100)
            AdjustmentSlider(title: "Halation (red glow)", value: $app.adjustments.halation, range: 0...1, neutral: d.halation, format: "%.0f%%", scale: 100)
            AdjustmentSlider(title: "Glow threshold", value: $app.adjustments.glowThreshold, range: 0.4...0.95, neutral: d.glowThreshold, format: "%.2f")
                .disabled(app.adjustments.bloom == 0 && app.adjustments.halation == 0)
            AdjustmentSlider(title: "Vignette", value: $app.adjustments.vignette, range: 0...1, neutral: d.vignette, format: "%.0f%%", scale: 100)
        }
    }

    private var grainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Film grain") {
                app.adjustments.grainAmount = Adjustments.startingPoint.grainAmount
                app.adjustments.grainSize = Adjustments.startingPoint.grainSize
            }
            AdjustmentSlider(title: "Amount", value: $app.adjustments.grainAmount, range: 0...1, neutral: 0, format: "%.0f%%", scale: 100)
            AdjustmentSlider(title: "Size", value: $app.adjustments.grainSize, range: 0.5...3, neutral: 1, format: "%.1f")
                .disabled(app.adjustments.grainAmount == 0)
        }
    }

    private var lutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("LUT library")

            if app.luts.count > 5 {
                TextField("Search LUTs", text: $app.lutFilter)
                    .textFieldStyle(.roundedBorder)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    lutRow(nil)
                    ForEach(app.filteredLUTs) { lutRow($0) }
                }
            }
            .frame(height: 210)
            .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.18)))

            if app.luts.isEmpty {
                Text("Add .cube files, or drop them onto the window. They're saved in the library for next time.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Add LUTs…") { app.addLUTPanel() }
                Button("Remove") { app.removeSelectedLUT() }
                    .disabled(app.selectedLUT == nil)
                Spacer()
                Button("Show in Finder") { app.revealLUTLibrary() }
                    .buttonStyle(TealLinkStyle()).font(.caption)
            }
            AdjustmentSlider(title: "Intensity", value: $app.lutIntensity, range: 0...1, neutral: 1, format: "%.0f%%", scale: 100)
                .disabled(app.selectedLUT == nil)
            Text("The LUT is applied after the enhance steps.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func lutRow(_ lut: LUT?) -> some View {
        let selected = app.selectedLUTID == lut?.id
        return HStack(spacing: 8) {
            Group {
                if let lut, let thumb = app.lutThumbs[lut.id] {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else if lut == nil, let thumb = app.photos.first(where: { $0.id == app.selectedID })?.thumbnail {
                    Image(nsImage: thumb).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 56, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(lut?.name ?? "None")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.orange.opacity(0.28) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { app.selectedLUTID = lut?.id }
        .contextMenu {
            if let lut {
                Button("Remove from library") { app.remove(lut) }
            }
        }
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Output color").font(.callout)
                Spacer()
                Picker("Output color", selection: $app.outputSpace) {
                    ForEach(OutputSpace.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            AdjustmentSlider(title: "JPEG quality", value: $app.jpegQuality, range: 0.7...1, neutral: 0.95, format: "%.0f", scale: 100)

            if let progress = app.exportProgress {
                ProgressView(value: progress)
                Button("Cancel") { app.cancelExport() }
            } else {
                Button {
                    app.exportAll()
                } label: {
                    Text(app.photos.count > 1 ? "Export \(app.photos.count) Photos…" : "Export…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlowButtonStyle())
                .disabled(app.photos.isEmpty)
            }

            if let message = app.message {
                Text(message)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    let format: String
    var scale: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .onTapGesture(count: 2) { value = neutral }
                Spacer()
                Text(String(format: format, value * scale))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: $value, in: range)
                .tint(Theme.teal)
        }
    }
}
