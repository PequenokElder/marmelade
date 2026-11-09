import SwiftUI

/// The Montage window: arrange your photos into vertical 9:16 frames, set the tempo, render an MP4.
struct MontageView: View {
    @ObservedObject var model: MontageModel
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            FrostedBackdrop()
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    previewColumn
                        .frame(width: 360)
                        .modifier(GlassPanel())
                    controlsColumn
                        .modifier(GlassPanel())
                }
                footer
            }
            .padding(.init(top: 14, leading: 14, bottom: 14, trailing: 14))
        }
        .preferredColorScheme(.dark)
        .tint(Theme.orange)
        .frame(width: 1000, height: 780)
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(spacing: 12) {
            SectionTitle("Preview")
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.05))
                if model.analyzing {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Looking at your photos…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let image = model.previewImage {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(6)
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))

            if model.scenes.count > 1 {
                Slider(value: Binding(get: { Double(model.previewIndex) },
                                      set: { model.previewIndex = Int($0.rounded()) }),
                       in: 0...Double(model.scenes.count - 1), step: 1)
                    .tint(Theme.teal)
            }
            Text(model.previewCaption).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    // MARK: Controls

    private var controlsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                framesCard.modifier(GlassCard())
                tempoCard.modifier(GlassCard())
                videoCard.modifier(GlassCard())
            }
            .padding(12)
        }
    }

    private var framesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Frames")
            Text("Photos per frame").font(.callout)
            Picker("Photos per frame", selection: $model.layoutMode) {
                ForEach(MontageLayoutMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(model.layoutMode == .auto
                 ? "Auto picks 2, 3 or 4 per frame from each photo's shape, so portraits and landscapes get slots that crop them least. Crops follow faces and the main subject."
                 : "Photos are cropped around faces and the main subject.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Order").font(.callout)
                Spacer()
                Picker("Order", selection: $model.order) {
                    ForEach(MontageOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            AdjustmentSlider(title: "Gap between photos", value: $model.gap, range: 0...24, neutral: 6, format: "%.0f px")
        }
    }

    private var tempoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Tempo")

            HStack(spacing: 8) {
                Text("BPM").font(.callout)
                TextField("BPM", value: $model.bpm, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Button("Tap") { model.tap() }
                    .buttonStyle(.bordered)
                    .help("Tap along with the music a few times")
                Button("½×") { model.bpm = max(30, (model.bpm / 2 * 10).rounded() / 10) }
                    .buttonStyle(.bordered)
                    .help("Half time, if the detected tempo is double what you feel")
                Button("2×") { model.bpm = min(300, (model.bpm * 2 * 10).rounded() / 10) }
                    .buttonStyle(.bordered)
                    .help("Double time, if the detected tempo is half what you feel")
                Spacer()
            }
            Slider(value: $model.bpm, in: 60...180, step: 1).tint(Theme.teal)

            Text("Cut every").font(.callout)
            Picker("Beats per cut", selection: $model.beatsPerCut) {
                Text("1 beat").tag(1)
                Text("2 beats").tag(2)
                Text("4 beats").tag(4)
                Text("8 beats").tag(8)
            }
            .pickerStyle(.segmented).labelsHidden()

            Divider().overlay(.white.opacity(0.12))

            if let music = model.musicURL {
                HStack {
                    Image(systemName: "music.note").foregroundStyle(Theme.teal)
                    Text(music.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { model.removeMusic() }.buttonStyle(TealLinkStyle()).font(.caption)
                }
                HStack {
                    Button(model.detecting ? "Listening…" : "Detect tempo from music") { model.detectTempo() }
                        .buttonStyle(.bordered)
                        .disabled(model.detecting)
                    if model.detecting { ProgressView().controlSize(.small) }
                }
                AdjustmentSlider(title: "First beat at (seconds into track)", value: $model.musicOffset, range: 0...10, neutral: 0, format: "%.2f s")
            } else {
                Button("Add music…") { model.chooseMusic() }.buttonStyle(.bordered)
                Text("Optional. Cuts land on the beat either way. With a track, the video starts on its first beat.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Video")
            Text("Transition").font(.callout)
            Picker("Transition", selection: $model.transition) {
                ForEach(MontageTransition.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack {
                Text("Size").font(.callout)
                Spacer()
                Picker("Size", selection: $model.quality) {
                    ForEach(MontageQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(.callout)
                if let status = model.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let progress = model.progress {
                ProgressView(value: progress).frame(width: 200)
                Button("Cancel") { model.cancelRender() }
            } else {
                Button("Close") { app.showMontage = false }
                Button("Render MP4…") { model.render() }
                    .buttonStyle(GlowButtonStyle())
                    .frame(width: 210)
                    .disabled(model.scenes.isEmpty || model.analyzing)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .modifier(GlassPanel(radius: 16))
    }

    private var summary: String {
        guard !model.scenes.isEmpty else { return model.analyzing ? "Analyzing…" : "Add at least two photos." }
        return String(format: "%d frames · %.1fs each (%d beats at %.0f BPM) · %.0fs total",
                      model.scenes.count, model.sceneDuration, model.beatsPerCut, model.bpm, model.totalDuration)
    }
}
