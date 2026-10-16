import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Hardware-accelerated frame extraction with AVFoundation.
///
/// Real phone footage is often variable-frame-rate, HDR (HLG / Dolby Vision) and stored with
/// rotation metadata. Everything here is rendered through a video composition onto a fixed
/// constant-frame-rate timeline, in display orientation and SDR Rec.709, so frame *k* of the
/// timeline is exactly frame *k + 1* in Blender. When the source isn't already a clean CFR SDR
/// upright video, the same frames are also written to a CFR plate for Blender to use.
enum VideoFrameExtractor {
    struct Plan {
        var sampling: FrameSampling
        var frameStep: Int
        var targetFPS: Double
        var maxFrames: Int          // 0 = unlimited
        var maxEdge: Int            // 0 = native
        var jpegQuality: Double     // 0…1
    }

    struct Result {
        var frames: [String: Int]   // JPEG name → 1-based frame on the CFR timeline
        var extractWidth: Int
        var extractHeight: Int
        var sourceWidth: Int        // display orientation
        var sourceHeight: Int
        var fps: Double             // timeline fps
        var frameCount: Int         // frames on the timeline
        var duration: Double
        var plateURL: URL?          // written when the source needed normalizing
        var notes: [String]
    }

    static let standardRates: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 119.88, 120, 240]

    static func extract(from url: URL, imagesDir: URL, plateURL: URL, plan: Plan,
                        progress: @escaping @MainActor (Double, String) -> Void) async throws -> Result {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PipelineError("No video track found.")
        }
        let (nominal, transform, natural, formats) = try await track.load(
            .nominalFrameRate, .preferredTransform, .naturalSize, .formatDescriptions)
        let duration = try await asset.load(.duration).seconds

        // Orientation & dynamic range
        let display = natural.applying(transform)
        let width = Int(abs(display.width).rounded()), height = Int(abs(display.height).rounded())
        let rotated = !transform.isIdentity
        let transfer = formats.first.flatMap {
            CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        }
        let hdr = transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
            || transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)

        // Timing: scan sample timestamps (no decoding) to detect variable frame rate.
        let pts = try await sampleTimes(asset: asset, track: track)
        let fps = timelineRate(nominal: Double(nominal), times: pts)
        let vfr = isVariable(times: pts, fps: fps)
        let frameCount = max(1, Int((duration * fps).rounded()))

        var notes: [String] = []
        if vfr { notes.append("Variable frame rate → \(format(fps)) fps constant timeline") }
        if hdr { notes.append("HDR → tone-mapped to SDR") }
        if rotated { notes.append("Rotation applied (\(width)×\(height))") }
        let needsPlate = vfr || hdr || rotated

        // Composition renders the CFR timeline, upright, in Rec.709.
        let comp = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        let timescale = Int32(max(600, Int((fps * 1000).rounded())))
        let frameDuration = CMTime(value: CMTimeValue((Double(timescale) / fps).rounded()), timescale: timescale)
        comp.frameDuration = frameDuration
        comp.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        comp.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        comp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        comp.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        comp.renderSize = CGSize(width: width, height: height)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [track],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = comp
        output.alwaysCopiesSampleData = false
        reader.add(output)

        // Optional CFR plate for Blender.
        var writer: AVAssetWriter?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if needsPlate {
            try? FileManager.default.removeItem(at: plateURL)
            let w = try AVAssetWriter(outputURL: plateURL, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width / 2 * 2,
                AVVideoHeightKey: height / 2 * 2,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(Double(width * height) * fps * 0.35),
                    AVVideoMaxKeyFrameIntervalKey: 12,
                    AVVideoExpectedSourceFrameRateKey: fps,
                ],
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
            input.expectsMediaDataInRealTime = false
            let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            w.add(input)
            guard w.startWriting() else { throw w.error ?? PipelineError("Could not create the plate video.") }
            w.startSession(atSourceTime: .zero)
            writer = w
            adaptor = a
        }

        guard reader.startReading() else { throw reader.error ?? PipelineError("Could not decode the video.") }

        // Scale for COLMAP frames
        var outW = width, outH = height
        if plan.maxEdge > 0, max(width, height) > plan.maxEdge {
            let s = Double(plan.maxEdge) / Double(max(width, height))
            outW = Int((Double(width) * s / 2).rounded()) * 2
            outH = Int((Double(height) * s / 2).rounded()) * 2
        }
        let scale = Double(outW) / Double(width)
        let writerPool = JPEGWriter(quality: plan.jpegQuality, scale: scale)

        var frames: [String: Int] = [:]
        var kept = 0
        var lastTargetSlot = -1
        let limit = plan.maxFrames > 0 ? plan.maxFrames : Int.max

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let k = max(0, Int((t * fps).rounded()))

            if let adaptor, let input = writer?.inputs.first {
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(2))
                }
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(k) * frameDuration.value,
                                                                     timescale: timescale))
            }

            var keep: Bool
            switch plan.sampling {
            case .everyNth:
                keep = k % max(1, plan.frameStep) == 0
            case .targetFPS:
                let slot = Int(Double(k) * plan.targetFPS / fps)
                keep = slot != lastTargetSlot
                if keep { lastTargetSlot = slot }
            }
            if keep && kept < limit {
                kept += 1
                let name = String(format: "frame_%06d.jpg", kept)
                frames[name] = k + 1
                await writerPool.write(buffer, to: imagesDir.appendingPathComponent(name))
            }

            if k % 8 == 0 {
                let p = min(1, Double(k) / Double(frameCount))
                let detail = "\(kept) frames · \(Int(p * 100))% of clip"
                await progress(p, detail)
            }
            // Without a plate we can stop as soon as we have enough frames.
            if writer == nil && kept >= limit { break }
        }
        reader.cancelReading()
        await writerPool.finish()

        if reader.status == .failed { throw reader.error ?? PipelineError("Video decoding failed.") }
        var plate: URL?
        if let writer {
            writer.inputs.first?.markAsFinished()
            await writer.finishWriting()
            if writer.status == .failed { throw writer.error ?? PipelineError("Writing the plate failed.") }
            plate = plateURL
        }
        guard kept > 0 else { throw PipelineError("No frames could be read from the video.") }

        return Result(frames: frames, extractWidth: outW, extractHeight: outH,
                      sourceWidth: width, sourceHeight: height, fps: fps, frameCount: frameCount,
                      duration: duration, plateURL: plate, notes: notes)
    }

    // MARK: Timing helpers

    /// Presentation timestamps of all video samples, read without decoding.
    private static func sampleTimes(asset: AVAsset, track: AVAssetTrack) async throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        reader.add(out)
        reader.startReading()
        var times: [Double] = []
        while let s = out.copyNextSampleBuffer() {
            // A compressed buffer can carry several samples; read every one's timing.
            if let timing = try? s.sampleTimingInfos() {
                for info in timing where info.presentationTimeStamp.isValid {
                    times.append(info.presentationTimeStamp.seconds)
                }
            }
        }
        return times.sorted()
    }

    /// The constant rate to use for the timeline: the nearest standard rate to the clip's fastest
    /// common frame interval, falling back to the track's nominal rate.
    static func timelineRate(nominal: Double, times: [Double]) -> Double {
        var deltas: [Double] = []
        for i in 1..<max(1, times.count) where times[i] > times[i - 1] { deltas.append(times[i] - times[i - 1]) }
        var raw = nominal
        if !deltas.isEmpty {
            deltas.sort()
            // Use the fast end of the interval distribution (ignoring near-duplicate stamps) so a
            // VFR clip's highest real frame rate is kept and no source frame is dropped.
            let median = deltas[deltas.count / 2]
            let real = deltas.filter { $0 > median * 0.5 }
            raw = 1 / real[real.count / 10]
        }
        if raw <= 0 || !raw.isFinite { raw = nominal > 0 ? nominal : 30 }
        let best = standardRates.min { abs($0 - raw) < abs($1 - raw) }!
        return abs(best - raw) / raw < 0.03 ? best : (raw * 1000).rounded() / 1000
    }

    /// True when frame intervals vary by more than a quarter frame from the timeline rate.
    static func isVariable(times: [Double], fps: Double) -> Bool {
        guard times.count > 2 else { return false }
        let expected = 1 / fps
        var irregular = 0
        for i in 1..<times.count {
            let d = times[i] - times[i - 1]
            if abs(d - expected) > expected * 0.25 { irregular += 1 }
        }
        return Double(irregular) / Double(times.count) > 0.01
    }

    private static func format(_ fps: Double) -> String {
        fps == fps.rounded() ? String(Int(fps)) : String(format: "%.3g", fps)
    }
}

/// Writes JPEGs on background threads (Core Image + ImageIO), a few at a time.
private actor JPEGWriter {
    private let quality: Double
    private let scale: Double
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var inFlight: [Task<Void, Never>] = []
    private let maxInFlight = max(2, ProcessInfo.processInfo.activeProcessorCount)

    init(quality: Double, scale: Double) {
        self.quality = quality
        self.scale = scale
    }

    func write(_ buffer: CVPixelBuffer, to url: URL) async {
        var image = CIImage(cvPixelBuffer: buffer)
        if scale < 0.999 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = image
            f.scale = Float(scale)
            f.aspectRatio = 1
            image = f.outputImage ?? image
        }
        let img = image
        let ctx = context
        let q = quality
        if inFlight.count >= maxInFlight {
            await inFlight.removeFirst().value
        }
        inFlight.append(Task.detached(priority: .userInitiated) {
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            try? ctx.writeJPEGRepresentation(of: img, to: url, colorSpace: space,
                                             options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: q])
        })
    }

    func finish() async {
        for t in inFlight { await t.value }
        inFlight.removeAll()
    }
}
