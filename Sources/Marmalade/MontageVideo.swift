import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Tempo

enum Tempo {
    /// Seconds each frame of the montage stays up: a whole number of beats at the given BPM.
    static func sceneDuration(bpm: Double, beatsPerCut: Int) -> Double {
        Double(beatsPerCut) * 60 / max(1, bpm)
    }

    /// BPM from tap timestamps (seconds). Uses the last few taps; returns nil until there are two.
    static func bpm(fromTaps taps: [TimeInterval]) -> Double? {
        let recent = Array(taps.suffix(8))
        guard recent.count >= 2 else { return nil }
        let intervals = zip(recent.dropFirst(), recent).map { $0 - $1 }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        guard mean > 0 else { return nil }
        return min(220, max(40, 60 / mean))
    }
}

/// Best-effort tempo and first-beat finder: onset strength from the audio, then a search for the
/// BPM whose beat grid lines up with it best. Good on steady, percussive music; check it by ear.
enum BeatDetector {
    struct Result {
        var bpm: Double
        var firstBeat: Double   // seconds into the track where a beat lands
    }

    static func detect(url: URL, maxSeconds: Double = 90) -> Result? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let wanted = AVAudioFrameCount(min(Double(file.length), maxSeconds * rate))
        guard wanted > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: wanted) else { return nil }
        do { try file.read(into: buffer, frameCount: wanted) } catch { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
        guard n > Int(rate) * 4 else { return nil }

        // Mono mix.
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channelCount { for i in 0..<n { mono[i] += channels[c][i] } }
        let norm = 1 / Float(channelCount)

        // Two onset curves: "bright" (energy of the first difference, favors drum hits and hats) and
        // "bass" (low-passed energy, favors kicks). Positive changes only, with a local average removed
        // so loud sections don't swamp quiet ones.
        let hop = 512
        let frames = n / hop
        let alpha = Float(1 - exp(-2 * Double.pi * 150 / rate))
        var bright = [Double](repeating: 0, count: frames)
        var bass = [Double](repeating: 0, count: frames)
        var low: Float = 0
        for j in 0..<frames {
            var eBright = 0.0, eBass = 0.0
            for k in 0..<hop {
                let i = j * hop + k
                let x = mono[i] * norm
                low += alpha * (x - low)
                eBass += Double(low * low)
                if i > 0 { let d = Double((mono[i] - mono[i - 1]) * norm); eBright += d * d }
            }
            bright[j] = sqrt(eBright / Double(hop))
            bass[j] = sqrt(eBass / Double(hop))
        }

        func onsets(_ energy: [Double]) -> [Double] {
            var raw = [Double](repeating: 0, count: frames)
            for j in 1..<frames { raw[j] = max(0, energy[j] - energy[j - 1]) }
            let window = 40
            var out = raw
            for j in 0..<frames {
                let lo = max(0, j - window), hi = min(frames - 1, j + window)
                var sum = 0.0
                for k in lo...hi { sum += raw[k] }
                out[j] = max(0, raw[j] - 1.2 * sum / Double(hi - lo + 1))
            }
            let peak = out.max() ?? 0
            return peak > 0 ? out.map { $0 / peak } : out
        }
        let brightOnsets = onsets(bright)
        let bassOnsets = onsets(bass)
        guard brightOnsets.contains(where: { $0 > 0 }) || bassOnsets.contains(where: { $0 > 0 }) else { return nil }

        let tempoCurve = zip(brightOnsets, bassOnsets).map { $0 + $1 }            // every kind of hit counts for tempo
        let beatCurve = zip(brightOnsets, bassOnsets).map { 0.3 * $0 + $1 }       // the beat itself follows the kick

        let frameRate = rate / Double(hop)
        func sample(_ curve: [Double], _ x: Double) -> Double {
            guard x >= 0, x < Double(frames - 1) else { return 0 }
            let i = Int(x), f = x - Double(i)
            return curve[i] * (1 - f) + curve[i + 1] * f
        }
        func autocorrelation(_ lag: Double) -> Double {
            var sum = 0.0
            var j = 0
            while Double(j) + lag < Double(frames - 1) {
                sum += tempoCurve[j] * sample(tempoCurve, Double(j) + lag)
                j += 1
            }
            return sum / Double(frames)
        }

        // Score each candidate tempo by how well onsets repeat at 1, 2 and 4 beats, with a mild
        // preference for everyday tempos so half- and double-time don't win by accident.
        var best = (bpm: 120.0, score: -Double.infinity)
        var bpm = 70.0
        while bpm <= 180 {
            let lag = 60 / bpm * frameRate
            let raw = autocorrelation(lag) + 0.5 * autocorrelation(lag * 2) + 0.25 * autocorrelation(lag * 4)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.8, 2))
            if raw * prior > best.score { best = (bpm, raw * prior) }
            bpm += 0.5
        }

        // Where in the first beat period do the (kick-weighted) onsets line up best?
        let period = 60 / best.bpm * frameRate
        var phase = (offset: 0.0, score: -Double.infinity)
        var offset = 0.0
        while offset < period {
            var sum = 0.0
            var x = offset
            while x < Double(frames - 1) { sum += sample(beatCurve, x); x += period }
            if sum > phase.score { phase = (offset, sum) }
            offset += 0.25
        }
        return Result(bpm: (best.bpm * 10).rounded() / 10, firstBeat: phase.offset / frameRate)
    }
}

// MARK: - Video

final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private final class Once {
    private let lock = NSLock()
    private var fired = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !fired { fired = true; body() }
    }
}

enum MontageVideoError: LocalizedError {
    case writer(String), cancelled
    var errorDescription: String? {
        switch self {
        case .writer(let m): return m
        case .cancelled: return "Cancelled."
        }
    }
}

enum MontageVideo {
    struct Music {
        var url: URL
        var offset: Double   // seconds into the track where video time 0 lands (its first beat)
    }

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Bakes a composed scene into a bitmap so every frame of its hold is cheap.
    static func rasterize(_ scene: CIImage, size: CGSize, context: CIContext) -> CIImage? {
        guard let cg = context.createCGImage(scene, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: colorSpace) else { return nil }
        return CIImage(cgImage: cg)
    }

    /// The picture at time `t`: the current scene, blending into the next one over the last moments
    /// of each scene so the new scene is fully in place exactly on the beat.
    static func frame(at t: Double, scenes: [CIImage], sceneDuration d: Double,
                      transition: MontageTransition, size: CGSize) -> CIImage {
        let index = min(scenes.count - 1, Int(t / d))
        let u = t - Double(index) * d
        let a = scenes[index]
        guard transition != .cut, index + 1 < scenes.count else { return a }
        let td = min(0.4, d * 0.5)
        guard u > d - td else { return a }

        let linear = (u - (d - td)) / td
        let p = linear * linear * (3 - 2 * linear)    // smoothstep
        let b = scenes[index + 1]
        let rect = CGRect(origin: .zero, size: size)

        switch transition {
        case .cut:
            return a
        case .fade:
            let f = CIFilter.dissolveTransition()
            f.inputImage = a
            f.targetImage = b
            f.time = Float(p)
            return f.outputImage?.cropped(to: rect) ?? a
        case .push:
            let up = a.transformed(by: CGAffineTransform(translationX: 0, y: p * size.height))
            let incoming = b.transformed(by: CGAffineTransform(translationX: 0, y: (p - 1) * size.height))
            return up.composited(over: incoming).cropped(to: rect)
        }
    }

    /// Writes an H.264 MP4 (with an AAC track if there's music).
    static func write(scenes: [CIImage], sceneDuration: Double, transition: MontageTransition, size: CGSize,
                      fps: Int32 = 30, music: Music?, to url: URL,
                      progress: @escaping (Double) -> Void, cancel: CancelFlag) async throws {
        let totalDuration = Double(scenes.count) * sceneDuration
        let totalFrames = Int((totalDuration * Double(fps)).rounded())
        guard totalFrames > 0 else { throw MontageVideoError.writer("Nothing to render.") }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: size.width >= 1080 ? 14_000_000 : 7_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(videoInput)

        // Optional music: decoded from the track and re-encoded to AAC, trimmed to the video length.
        var audioInput: AVAssetWriterInput?
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        if let music {
            let asset = AVURLAsset(url: music.url)
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let reader = try AVAssetReader(asset: asset)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: music.offset, preferredTimescale: 600),
                                               duration: CMTime(seconds: totalDuration, preferredTimescale: 600))
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                ])
                reader.add(output)
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ])
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                audioInput = input; audioReader = reader; audioOutput = output
            }
        }

        guard writer.startWriting() else {
            throw MontageVideoError.writer(writer.error?.localizedDescription ?? "Couldn't start writing the video.")
        }
        writer.startSession(atSourceTime: .zero)
        if let audioReader, !audioReader.startReading() {
            throw MontageVideoError.writer(audioReader.error?.localizedDescription ?? "Couldn't read the music file.")
        }

        let context = CIContext(options: [.workingColorSpace: colorSpace, .outputColorSpace: colorSpace])
        let group = DispatchGroup()

        // Video frames
        let videoQueue = DispatchQueue(label: "marmalade.montage.video")
        let videoDone = Once()
        var frameIndex = 0
        group.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                if cancel.isSet || frameIndex >= totalFrames {
                    videoInput.markAsFinished()
                    videoDone.run { group.leave() }
                    return
                }
                guard let pool = adaptor.pixelBufferPool else { continue }
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard let buffer = pixelBuffer else { continue }

                let t = Double(frameIndex) / Double(fps)
                let image = frame(at: t, scenes: scenes, sceneDuration: sceneDuration, transition: transition, size: size)
                context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: fps))
                frameIndex += 1
                if frameIndex % 6 == 0 { progress(Double(frameIndex) / Double(totalFrames)) }
            }
        }

        // Music samples, shifted so the chosen first beat lands at video time 0
        if let audioInput, let audioOutput {
            let audioQueue = DispatchQueue(label: "marmalade.montage.audio")
            let audioDone = Once()
            let shift = CMTime(seconds: music?.offset ?? 0, preferredTimescale: 600)
            group.enter()
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    if cancel.isSet {
                        audioInput.markAsFinished()
                        audioDone.run { group.leave() }
                        return
                    }
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        audioDone.run { group.leave() }
                        return
                    }
                    if let moved = retimed(sample, subtracting: shift) { audioInput.append(moved) }
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }

        if cancel.isSet {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw MontageVideoError.cancelled
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw MontageVideoError.writer(writer.error?.localizedDescription ?? "The video couldn't be written.")
        }
        progress(1)
    }

    private static func retimed(_ sample: CMSampleBuffer, subtracting delta: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in 0..<count {
            timings[i].presentationTimeStamp = CMTimeSubtract(timings[i].presentationTimeStamp, delta)
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, delta) }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timings, sampleBufferOut: &out)
        return out
    }
}
