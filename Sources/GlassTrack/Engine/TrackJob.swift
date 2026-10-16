import AppKit
import AVFoundation
import Foundation
import Observation

struct PipelineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One camera-tracking job: video/photos in → COLMAP solve → Blender scene out.
@MainActor
@Observable
final class TrackJob: Identifiable {
    let id: UUID
    var name: String
    let inputURL: URL
    let inputKind: InputKind
    var settings: JobSettings
    var outputRoot: URL

    var status: JobStatus = .idle
    var stages: [StageProgress] = StageID.allCases.map { StageProgress(id: $0) }
    var log: [String] = []
    var videoInfo: VideoInfo?
    var imageCount = 0
    var thumbnail: NSImage?
    var stats: SolveStats?
    var model: SparseModel?
    var startedAt: Date?
    var finishedAt: Date?
    var blendURL: URL?
    var createdAt = Date()

    /// Called for every log line (used by the command line mode).
    @ObservationIgnored var onLog: ((String) -> Void)?
    /// Called whenever state worth saving changes (stage boundaries, finish).
    @ObservationIgnored var onPersist: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var extractSize: (Int, Int)?

    var projectDir: URL { outputRoot.appendingPathComponent(folderName, isDirectory: true) }
    @ObservationIgnored private(set) lazy var folderName: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(name.replacingOccurrences(of: "/", with: "-"))_\(f.string(from: createdAt))"
    }()

    var imagesDir: URL { projectDir.appendingPathComponent("images", isDirectory: true) }
    var databaseURL: URL { projectDir.appendingPathComponent("database.db") }
    var sparseDir: URL { projectDir.appendingPathComponent("sparse", isDirectory: true) }
    var textModelDir: URL { projectDir.appendingPathComponent("sparse_txt", isDirectory: true) }
    var undistortedDir: URL { projectDir.appendingPathComponent("undistorted", isDirectory: true) }

    init(input: URL, settings: JobSettings, outputRoot: URL) {
        id = UUID()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: input.path, isDirectory: &isDir)
        inputURL = input
        inputKind = isDir.boolValue ? .imageFolder : .video
        name = input.deletingPathExtension().lastPathComponent
        self.settings = settings
        self.outputRoot = outputRoot
    }

    // MARK: Persistence

    init(snapshot s: JobSnapshot) {
        id = s.id
        name = s.name
        inputURL = URL(fileURLWithPath: s.inputPath)
        inputKind = s.inputKind
        settings = s.settings
        outputRoot = URL(fileURLWithPath: s.outputRoot)
        createdAt = s.createdAt
        status = s.status
        stages = s.stages
        log = s.log
        videoInfo = s.videoInfo
        imageCount = s.imageCount
        stats = s.stats
        startedAt = s.startedAt
        finishedAt = s.finishedAt
        blendURL = s.blendPath.map { URL(fileURLWithPath: $0) }
        frameMap = s.frameMap
        platePath = s.platePath
        if let w = s.extractWidth, let h = s.extractHeight { extractSize = (w, h) }
        folderName = s.folderName

        // A solve that was running when the app quit resumes from its last finished stage.
        if status == .running {
            status = .idle
            for i in stages.indices where stages[i].state == .running {
                stages[i] = StageProgress(id: stages[i].id)
            }
            log.append("── Resuming after relaunch ──")
        }
        if status == .finished {
            model = SparseModel.load(from: textModelDir)
        }
    }

    var snapshot: JobSnapshot {
        JobSnapshot(id: id, name: name, inputPath: inputURL.path, inputKind: inputKind, settings: settings,
                    outputRoot: outputRoot.path, folderName: folderName, createdAt: createdAt,
                    status: status, stages: stages, log: Array(log.suffix(400)), videoInfo: videoInfo,
                    imageCount: imageCount, stats: stats, startedAt: startedAt, finishedAt: finishedAt,
                    blendPath: blendURL?.path, frameMap: frameMap,
                    extractWidth: extractSize?.0, extractHeight: extractSize?.1, platePath: platePath)
    }

    /// Restores the thumbnail of a track loaded from disk.
    func loadThumbnail() async {
        guard thumbnail == nil else { return }
        if inputKind == .video, FileManager.default.fileExists(atPath: inputURL.path) {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: inputURL))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1200, height: 1200)
            if let cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
                thumbnail = NSImage(cgImage: cg, size: .zero)
                return
            }
        }
        let first = Self.listImages(in: imagesDir).first ?? Self.listImages(in: inputURL).first
        if let first { thumbnail = NSImage(contentsOf: first) }
    }

    // MARK: Derived state

    var overallProgress: Double {
        let active = stages.filter { $0.state != .skipped }
        let total = active.reduce(0) { $0 + $1.id.weight }
        guard total > 0 else { return 0 }
        let done = active.reduce(0.0) { acc, s in
            switch s.state {
            case .done: acc + s.id.weight
            case .running: acc + s.id.weight * max(0, s.fraction)
            default: acc
            }
        }
        return min(1, done / total)
    }

    var currentStage: StageProgress? { stages.first { $0.state == .running } }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var eta: TimeInterval? {
        let p = overallProgress
        guard status == .running, p > 0.03 else { return nil }
        return elapsed / p * (1 - p)
    }

    // MARK: Control

    func start() {
        guard status != .running else { return }
        status = .running   // set now so a second pump() can't start this job twice
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    func loadInputPreview() async {
        if inputKind == .video {
            if let ffprobe = ToolLocator.ffprobe() {
                videoInfo = try? await Self.probe(inputURL, ffprobe: ffprobe)
            }
            let asset = AVURLAsset(url: inputURL)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1200, height: 1200)
            if let cg = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image {
                thumbnail = NSImage(cgImage: cg, size: .zero)
            }
        } else {
            let imgs = Self.listImages(in: inputURL)
            imageCount = imgs.count
            if let first = imgs.first { thumbnail = NSImage(contentsOf: first) }
            if let first = imgs.first, let rep = NSImageRep(contentsOf: first) {
                videoInfo = VideoInfo(width: rep.pixelsWide, height: rep.pixelsHigh, fps: 24,
                                      frameCount: imgs.count, duration: Double(imgs.count) / 24)
            }
        }
    }

    /// Estimated number of frames that will be sent to COLMAP.
    var estimatedFrames: Int {
        guard let v = videoInfo else { return imageCount }
        var n: Int
        if inputKind == .imageFolder {
            n = imageCount
        } else if settings.sampling == .everyNth {
            n = Int((Double(v.frameCount) / Double(max(1, settings.frameStep))).rounded(.up))
        } else {
            n = Int(v.duration * settings.targetFPS)
        }
        if settings.maxFrames > 0 { n = min(n, settings.maxFrames) }
        return n
    }

    // MARK: Pipeline

    private func isDone(_ id: StageID) -> Bool { stages.first { $0.id == id }?.state == .done }

    /// Runs the pipeline. Stages already marked done (from an earlier, interrupted run) are skipped.
    private func run() async {
        let resuming = stages.contains { $0.state == .done }
        status = .running
        startedAt = Date()
        finishedAt = nil
        if resuming {
            for i in stages.indices where stages[i].state != .done {
                stages[i] = StageProgress(id: stages[i].id)
            }
        } else {
            stats = nil
            model = nil
            blendURL = nil
            stages = StageID.allCases.map { StageProgress(id: $0) }
        }
        if !settings.undistort { setState(.undistort, .skipped) }
        if !settings.buildBlend || ToolLocator.blender() == nil { setState(.blender, .skipped) }
        onPersist?()

        do {
            guard let colmap = ToolLocator.colmap() else { throw PipelineError("COLMAP is not installed.") }
            try prepareFolders(resetDatabase: !isDone(.features))
            emit(resuming ? "Resuming in \(projectDir.path)" : "Project folder: \(projectDir.path)")

            if !isDone(.extract) { try await stage(.extract) { try await self.extractFrames() } }
            if !isDone(.features) { try await stage(.features) { try await self.featureExtraction(colmap) } }
            if !isDone(.matching) { try await stage(.matching) { try await self.matching(colmap) } }
            let best = isDone(.mapping)
                ? try bestModel()
                : try await stage(.mapping) { try await self.mapping(colmap) }
            if settings.undistort && !isDone(.undistort) {
                try await stage(.undistort) { try await self.undistort(colmap, model: best) }
            }
            if !isDone(.export) { try await stage(.export) { try await self.export(colmap, model: best) } }
            if stages.first(where: { $0.id == .blender })?.state == .pending {
                try await stage(.blender) { try await self.buildBlend() }
            }
            status = .finished
            emit("✓ Solve finished in \(Self.format(elapsed)).")
        } catch is CancellationError {
            status = .cancelled
            markRunning(as: .failed("Cancelled"))
            emit("Cancelled.")
        } catch {
            let msg = error.localizedDescription
            status = .failed(msg)
            markRunning(as: .failed(msg))
            emit("✗ \(msg)")
        }
        finishedAt = Date()
        onPersist?()
    }

    /// Clears progress so the next start solves from scratch.
    func resetProgress() {
        status = .idle
        stages = StageID.allCases.map { StageProgress(id: $0) }
        stats = nil
        model = nil
        blendURL = nil
    }

    @discardableResult
    private func stage<T>(_ id: StageID, _ body: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        update(id) { $0.state = .running; $0.fraction = 0; $0.startedAt = Date(); $0.detail = "" }
        emit("── \(id.title) ──")
        let result = try await body()
        update(id) { $0.state = .done; $0.fraction = 1; $0.finishedAt = Date() }
        onPersist?()
        return result
    }

    private func prepareFolders(resetDatabase: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sparseDir, withIntermediateDirectories: true)
        if resetDatabase { try? fm.removeItem(at: databaseURL) }
    }

    // 1. Frames

    private func extractFrames() async throws {
        if inputKind == .imageFolder {
            let imgs = Self.listImages(in: inputURL)
            guard !imgs.isEmpty else { throw PipelineError("No images found in the folder.") }
            let limit = settings.maxFrames > 0 ? min(settings.maxFrames, imgs.count) : imgs.count
            var frames: [String: Int] = [:]
            for (i, src) in imgs.prefix(limit).enumerated() {
                let name = String(format: "frame_%06d.%@", i + 1, src.pathExtension.lowercased())
                let dst = imagesDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: src)
                frames[name] = i + 1
                if i % 20 == 0 { update(.extract) { $0.fraction = Double(i) / Double(limit); $0.detail = "\(i)/\(limit) images" } }
            }
            imageCount = limit
            frameMap = frames
            if let v = videoInfo { extractSize = (v.width, v.height) }
            update(.extract) { $0.detail = "\(limit) images linked" }
            return
        }

        do {
            try await extractWithAVFoundation()
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            emit("AVFoundation couldn't read this file (\(error.localizedDescription)); using FFmpeg.")
            platePath = nil
        }

        guard let ffmpeg = ToolLocator.ffmpeg(), let ffprobe = ToolLocator.ffprobe() else {
            throw PipelineError("FFmpeg is not installed.")
        }
        let info: VideoInfo
        if let v = videoInfo { info = v } else {
            info = try await Self.probe(inputURL, ffprobe: ffprobe)
            videoInfo = info
        }

        var filters: [String] = []
        switch settings.sampling {
        case .everyNth:
            let n = max(1, settings.frameStep)
            if n > 1 { filters.append("select=not(mod(n\\,\(n)))") }
        case .targetFPS:
            filters.append("fps=\(settings.targetFPS)")
        }
        var outW = info.width, outH = info.height
        let edge = settings.quality.frameMaxEdge
        if edge > 0, max(info.width, info.height) > edge {
            let s = Double(edge) / Double(max(info.width, info.height))
            outW = Int((Double(info.width) * s / 2).rounded()) * 2
            outH = Int((Double(info.height) * s / 2).rounded()) * 2
            filters.append("scale=\(outW):\(outH):flags=lanczos")
        }
        extractSize = (outW, outH)

        let expected = max(1, estimatedFrames)
        var args = ["-hide_banner", "-nostdin", "-y", "-i", inputURL.path, "-map", "0:v:0"]
        if !filters.isEmpty { args += ["-vf", filters.joined(separator: ",")] }
        args += ["-fps_mode", "passthrough", "-q:v", "\(settings.jpegQuality)", "-start_number", "1"]
        if settings.maxFrames > 0 { args += ["-frames:v", "\(settings.maxFrames)"] }
        args += ["-progress", "pipe:1", "-nostats", "-loglevel", "error",
                 imagesDir.appendingPathComponent("frame_%06d.jpg").path]

        try await exec(ffmpeg, args, stage: .extract) { line, job in
            if line.hasPrefix("frame="), let n = Int(line.dropFirst(6)) {
                job.update(.extract) {
                    $0.fraction = min(1, Double(n) / Double(expected))
                    $0.detail = "\(n) / ~\(expected) frames"
                }
                return true
            }
            return line.contains("=") && !line.contains(" ")  // hide other progress keys
        }

        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path))?
            .filter { $0.hasSuffix(".jpg") }.sorted() ?? []
        guard !files.isEmpty else { throw PipelineError("FFmpeg produced no frames.") }
        imageCount = files.count

        var frames: [String: Int] = [:]
        for (i, f) in files.enumerated() {
            switch settings.sampling {
            case .everyNth: frames[f] = i * max(1, settings.frameStep) + 1
            case .targetFPS: frames[f] = Int((Double(i) * info.fps / settings.targetFPS).rounded()) + 1
            }
        }
        frameMap = frames
        update(.extract) { $0.detail = "\(files.count) frames @ \(outW)×\(outH)" }
    }

    /// Normalised plate written for VFR / HDR / rotated sources (nil = use the original video).
    var platePath: String?

    private func extractWithAVFoundation() async throws {
        let jpegQ: Double = settings.jpegQuality <= 2 ? 0.95 : settings.jpegQuality <= 4 ? 0.9 : 0.8
        let plan = VideoFrameExtractor.Plan(sampling: settings.sampling, frameStep: settings.frameStep,
                                            targetFPS: settings.targetFPS, maxFrames: settings.maxFrames,
                                            maxEdge: settings.quality.frameMaxEdge, jpegQuality: jpegQ)
        let r = try await VideoFrameExtractor.extract(
            from: inputURL, imagesDir: imagesDir,
            plateURL: projectDir.appendingPathComponent("plate.mp4"), plan: plan
        ) { [weak self] fraction, detail in
            self?.update(.extract) { $0.fraction = fraction; $0.detail = detail }
        }
        for note in r.notes { emit(note) }
        frameMap = r.frames
        imageCount = r.frames.count
        extractSize = (r.extractWidth, r.extractHeight)
        platePath = r.plateURL?.path
        videoInfo = VideoInfo(width: r.sourceWidth, height: r.sourceHeight, fps: r.fps,
                              frameCount: r.frameCount, duration: r.duration)
        var detail = "\(r.frames.count) frames @ \(r.extractWidth)×\(r.extractHeight)"
        if !r.notes.isEmpty { detail += " · " + r.notes.map { $0.components(separatedBy: " →").first ?? $0 }.joined(separator: ", ") }
        update(.extract) { $0.detail = detail }
    }

    @ObservationIgnored private var frameMap: [String: Int] = [:]

    // 2. Features

    private func featureExtraction(_ colmap: String) async throws {
        let q = settings.quality
        let total = imageCount
        var args = ["feature_extractor",
                    "--database_path", databaseURL.path,
                    "--image_path", imagesDir.path,
                    "--ImageReader.camera_model", settings.cameraModel.rawValue,
                    "--ImageReader.single_camera", settings.singleCamera ? "1" : "0",
                    "--FeatureExtraction.use_gpu", settings.useGPU ? "1" : "0",
                    "--FeatureExtraction.max_image_size", "\(q.maxImageSize)",
                    "--SiftExtraction.max_num_features", "\(q.maxFeatures)"]
        if q == .high || q == .ultra {
            args += ["--SiftExtraction.estimate_affine_shape", "0", "--SiftExtraction.domain_size_pooling", "1"]
        }
        try await exec(colmap, args + Self.logArgs, stage: .features) { line, job in
            if let (i, n) = Self.bracketProgress(line) {
                job.update(.features) {
                    $0.fraction = Double(i) / Double(max(n, 1))
                    $0.detail = "Image \(i) of \(n)"
                }
                return line.contains("Processed file")
            }
            _ = total
            return false
        }
    }

    // 3. Matching

    private func matching(_ colmap: String) async throws {
        let sequential = settings.matcher == .sequential
        var args: [String]
        if sequential {
            args = ["sequential_matcher",
                    "--database_path", databaseURL.path,
                    "--SequentialMatching.overlap", "\(settings.quality.sequentialOverlap)",
                    "--SequentialMatching.quadratic_overlap", "1",
                    "--SequentialMatching.loop_detection", settings.loopDetection ? "1" : "0",
                    "--FeatureMatching.use_gpu", settings.useGPU ? "1" : "0"]
        } else {
            args = ["exhaustive_matcher",
                    "--database_path", databaseURL.path,
                    "--FeatureMatching.use_gpu", settings.useGPU ? "1" : "0"]
        }
        try await exec(colmap, args + Self.logArgs, stage: .matching) { line, job in
            if sequential, let (i, n) = Self.bracketProgress(line) {
                job.update(.matching) { $0.fraction = Double(i) / Double(max(n, 1)); $0.detail = "Image \(i) of \(n)" }
            } else if let r = line.range(of: #"block \[(\d+)/(\d+), (\d+)/(\d+)\]"#, options: .regularExpression) {
                let nums = line[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if nums.count == 4 {
                    let done = Double((nums[0] - 1) * nums[3] + nums[2])
                    let all = Double(nums[1] * nums[3])
                    job.update(.matching) { $0.fraction = done / max(all, 1); $0.detail = "Block \(Int(done)) of \(Int(all))" }
                }
            }
            return false
        }
    }

    // 4. Mapping

    private func mapping(_ colmap: String) async throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: sparseDir)
        try fm.createDirectory(at: sparseDir, withIntermediateDirectories: true)
        let total = imageCount

        if settings.mapper == .global {
            let args = ["global_mapper",
                        "--database_path", databaseURL.path,
                        "--image_path", imagesDir.path,
                        "--output_path", sparseDir.path,
                        "--GlobalMapper.gp_use_gpu", "0",
                        "--GlobalMapper.ba_ceres_use_gpu", "0"]
            update(.mapping) { $0.fraction = -1; $0.detail = "Global solve…" }
            try await exec(colmap, args + Self.logArgs, stage: .mapping) { line, job in
                for (key, label) in [("rotation", "Rotation averaging"), ("track", "Building tracks"),
                                     ("position", "Global positioning"), ("bundle", "Bundle adjustment"),
                                     ("triangulat", "Retriangulation")]
                where line.lowercased().contains(key) {
                    job.update(.mapping) { $0.detail = label }
                    break
                }
                return false
            }
        } else {
            let args = ["mapper",
                        "--database_path", databaseURL.path,
                        "--image_path", imagesDir.path,
                        "--output_path", sparseDir.path,
                        "--Mapper.ba_refine_principal_point", "0",
                        "--Mapper.ba_refine_focal_length", "1",
                        "--Mapper.ba_refine_extra_params", settings.cameraModel == .pinhole || settings.cameraModel == .simplePinhole ? "0" : "1"]
            try await exec(colmap, args + Self.logArgs, stage: .mapping) { line, job in
                // COLMAP 3: "Registering image #42 (17)"; COLMAP 4: "Registering image #229 (num_reg_frames=90)"
                if line.contains("Registering image #"),
                   let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close,
                   let n = Int(line[line.index(after: open)..<close].split(separator: "=").last ?? "") {
                    job.update(.mapping) {
                        $0.fraction = Double(n) / Double(max(total, 1))
                        $0.detail = "Registered \(n) of \(total) frames"
                    }
                } else if line.contains("Initializing with image pair") || line.contains("initial image pair") {
                    job.update(.mapping) { $0.detail = "Finding initial pair…" }
                } else if line.lowercased().contains("global bundle adjustment") || line.contains("Bundle adjustment report") {
                    job.update(.mapping) { if !$0.detail.contains("bundle") { $0.detail += $0.detail.isEmpty ? "Bundle adjustment" : " · bundle adjust" } }
                }
                return false
            }
        }

        let best = try bestModel()
        let models = ((try? fm.contentsOfDirectory(at: sparseDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("images.bin").path) }
        let reg = registeredImageCount(inBinaryModel: best)
        if models.count > 1 {
            emit("COLMAP produced \(models.count) partial models; using the largest (\(reg) frames).")
        }
        update(.mapping) { $0.detail = "Solved \(reg) of \(total) frames" }
        return best
    }

    /// The sub-model with the most registered frames.
    private func bestModel() throws -> URL {
        let fm = FileManager.default
        let models = ((try? fm.contentsOfDirectory(at: sparseDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("images.bin").path) }
        guard let best = models.max(by: { registeredImageCount(inBinaryModel: $0) < registeredImageCount(inBinaryModel: $1) })
        else {
            throw PipelineError("COLMAP could not solve the camera. Try a smaller frame step, a higher quality preset, or footage with more parallax.")
        }
        return best
    }

    // 5. Undistort

    private func undistort(_ colmap: String, model: URL) async throws {
        try? FileManager.default.removeItem(at: undistortedDir)
        let total = imageCount
        let args = ["image_undistorter",
                    "--image_path", imagesDir.path,
                    "--input_path", model.path,
                    "--output_path", undistortedDir.path,
                    "--output_type", "COLMAP"]
        var count = 0
        try await exec(colmap, args + Self.logArgs, stage: .undistort) { line, job in
            if line.contains("Undistorting image") {
                count += 1
                let c = count
                job.update(.undistort) { $0.fraction = Double(c) / Double(max(total, 1)); $0.detail = "\(c) frames" }
            } else if let (i, n) = Self.bracketProgress(line) {
                job.update(.undistort) { $0.fraction = Double(i) / Double(max(n, 1)); $0.detail = "Frame \(i) of \(n)" }
            }
            return false
        }
    }

    // 6. Export

    private func export(_ colmap: String, model: URL) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: textModelDir)
        try fm.createDirectory(at: textModelDir, withIntermediateDirectories: true)
        try await exec(colmap, ["model_converter", "--input_path", model.path,
                                "--output_path", textModelDir.path, "--output_type", "TXT"] + Self.logArgs,
                       stage: .export) { _, _ in false }
        update(.export) { $0.fraction = 0.4; $0.detail = "Analyzing solve…" }

        var s = SolveStats(totalImages: imageCount)
        try await exec(colmap, ["model_analyzer", "--path", model.path] + Self.logArgs, stage: .export) { line, _ in
            func value(_ key: String) -> Double? {
                guard let r = line.range(of: key + ":") else { return nil }
                let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
                return Double(rest.prefix { $0.isNumber || $0 == "." })
            }
            if let v = value("Registered images") { s.registeredImages = Int(v) }
            if let v = value("Points") { s.points = Int(v) }
            if let v = value("Mean track length") { s.meanTrackLength = v }
            if let v = value("Mean reprojection error") { s.meanReprojectionError = v }
            return false
        }
        stats = s

        var modelForBlender = "sparse_txt"
        if settings.undistort {
            let undistTxt = projectDir.appendingPathComponent("undistorted_txt")
            try? fm.removeItem(at: undistTxt)
            try fm.createDirectory(at: undistTxt, withIntermediateDirectories: true)
            try await exec(colmap, ["model_converter", "--input_path", undistortedDir.appendingPathComponent("sparse").path,
                                    "--output_path", undistTxt.path, "--output_type", "TXT"] + Self.logArgs,
                           stage: .export) { _, _ in false }
            modelForBlender = "undistorted_txt"
        }

        update(.export) { $0.fraction = 0.7; $0.detail = "Writing Blender script…" }
        try writeBlenderFiles(modelDir: modelForBlender)
        self.model = SparseModel.load(from: textModelDir)
        update(.export) { $0.detail = "\(s.registeredImages) cameras · \(s.points.formatted()) points" }
    }

    private func writeBlenderFiles(modelDir: String) throws {
        let v = videoInfo
        var meta: [String: Any] = [
            "name": name,
            "model": modelDir,
            "frames": frameMap,
            "fps": v?.fps ?? 24,
            "frameCount": inputKind == .video ? (v?.frameCount ?? 0) : imageCount,
            "sourceWidth": v?.width ?? 0,
            "sourceHeight": v?.height ?? 0,
            "extractWidth": extractSize?.0 ?? v?.width ?? 0,
            "extractHeight": extractSize?.1 ?? v?.height ?? 0,
            "undistorted": settings.undistort,
            "targetSceneSize": 8.0,
            "maxPoints": 300_000,
        ]
        if settings.undistort && (inputKind == .imageFolder || settings.frameStep == 1 && settings.sampling == .everyNth) {
            // Every frame was undistorted, so the undistorted sequence is a full plate.
            meta["plate"] = "undistorted/images/" + (frameMap.keys.sorted().first ?? "frame_000001.jpg")
        } else if inputKind == .video {
            meta["plate"] = platePath ?? inputURL.path
            meta["undistorted"] = false
            if settings.undistort { meta["model"] = "sparse_txt" }  // keep plate & lens consistent
        } else {
            meta["plate"] = "images/" + (frameMap.keys.sorted().first ?? "frame_000001.jpg")
        }
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: projectDir.appendingPathComponent("track_meta.json"))
        try BlenderScript.source.write(to: projectDir.appendingPathComponent(BlenderScript.fileName),
                                       atomically: true, encoding: .utf8)
    }

    // 7. Blender

    private func buildBlend() async throws {
        guard let blender = ToolLocator.blender() else { return }
        let out = projectDir.appendingPathComponent("\(name)_track.blend")
        update(.blender) { $0.fraction = -1; $0.detail = "Launching Blender in background…" }
        try await exec(blender, ["--background", "--factory-startup",
                                 "--python", projectDir.appendingPathComponent(BlenderScript.fileName).path,
                                 "--", "--meta", projectDir.appendingPathComponent("track_meta.json").path,
                                 "--out", out.path],
                       stage: .blender) { line, job in
            if line.hasPrefix("GlassTrack:") {
                job.update(.blender) { $0.detail = String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces) }
            }
            return false
        }
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw PipelineError("Blender did not write the scene file.")
        }
        blendURL = out
        update(.blender) { $0.detail = out.lastPathComponent }
    }

    // MARK: Helpers

    static let logArgs = ["--log_target", "stderr", "--log_color", "0"]

    /// Runs a tool, piping lines to the log. `parse` returns true to hide a line from the log.
    private func exec(_ tool: String, _ args: [String], stage: StageID,
                      parse: @escaping (String, TrackJob) -> Bool) async throws {
        emit("$ \(URL(fileURLWithPath: tool).lastPathComponent) \(args.prefix(1).joined())")
        // Tools like COLMAP print many lines per second; hand them to the UI in batches
        // (~10 per second) so the screen isn't redrawn for every line.
        let batcher = LineBatcher { [weak self] lines in
            MainActor.assumeIsolated {
                guard let self else { return }
                for line in lines where !parse(line, self) {
                    self.emit(Self.cleanLog(line))
                }
            }
        }
        try await ProcessRunner.run(tool, args, workingDirectory: projectDir) { line in
            batcher.add(line)
        }
        // Deliver whatever is still queued before the stage completes.
        await withCheckedContinuation { c in
            DispatchQueue.main.async {
                batcher.flush()
                c.resume()
            }
        }
    }

    func update(_ id: StageID, _ change: (inout StageProgress) -> Void) {
        guard let i = stages.firstIndex(where: { $0.id == id }) else { return }
        change(&stages[i])
    }

    private func setState(_ id: StageID, _ state: StageState) { update(id) { $0.state = state } }

    private func markRunning(as state: StageState) {
        for i in stages.indices where stages[i].state == .running {
            stages[i].state = state
            stages[i].finishedAt = Date()
        }
    }

    func emit(_ line: String) {
        log.append(line)
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
        onLog?(line)
    }

    /// Strips the glog prefix: "I20261016 11:37:24.353671 0x208b44f80 file.cc:123] message"
    static func cleanLog(_ line: String) -> String {
        if let r = line.range(of: "] "), line.first.map({ "IWEF".contains($0) }) == true,
           line.distance(from: line.startIndex, to: r.lowerBound) < 80 {
            return String(line[r.upperBound...])
        }
        return line
    }

    static func bracketProgress(_ line: String) -> (Int, Int)? {
        guard let r = line.range(of: #"\[(\d+)/(\d+)\]"#, options: .regularExpression) else { return nil }
        let nums = line[r].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return nums.count == 2 ? (nums[0], nums[1]) : nil
    }

    static func listImages(in dir: URL) -> [URL] {
        let exts: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "bmp", "webp"]
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func probe(_ url: URL, ffprobe: String) async throws -> VideoInfo {
        let out = OutputBox()
        try await ProcessRunner.run(ffprobe, ["-v", "error", "-select_streams", "v:0",
                                              "-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration:stream_side_data=rotation:format=duration",
                                              "-of", "json", url.path]) { out.append($0) }
        guard let data = out.text.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = (json["streams"] as? [[String: Any]])?.first,
              var w = stream["width"] as? Int, var h = stream["height"] as? Int
        else { throw PipelineError("Could not read the video file.") }

        func rate(_ s: Any?) -> Double? {
            guard let s = s as? String else { return nil }
            let p = s.split(separator: "/").compactMap { Double($0) }
            guard p.count == 2, p[1] > 0, p[0] > 0 else { return nil }
            return p[0] / p[1]
        }
        let fps = rate(stream["avg_frame_rate"]) ?? rate(stream["r_frame_rate"]) ?? 24
        let duration = Double(stream["duration"] as? String ?? "")
            ?? Double((json["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        let frames = Int(stream["nb_frames"] as? String ?? "") ?? Int((duration * fps).rounded())
        if let side = stream["side_data_list"] as? [[String: Any]],
           let rot = side.compactMap({ $0["rotation"] as? Int ?? ($0["rotation"] as? Double).map(Int.init) }).first,
           abs(rot) % 180 == 90 {
            swap(&w, &h)
        }
        return VideoInfo(width: w, height: h, fps: fps, frameCount: frames, duration: duration)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Collects lines from a background reader and delivers them on the main queue at most every 0.1 s.
private final class LineBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var scheduled = false
    private let deliver: ([String]) -> Void

    init(deliver: @escaping ([String]) -> Void) { self.deliver = deliver }

    func add(_ line: String) {
        lock.lock()
        pending.append(line)
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.flush() }
        }
    }

    /// Must be called on the main queue.
    func flush() {
        lock.lock()
        let lines = pending
        pending.removeAll()
        scheduled = false
        lock.unlock()
        if !lines.isEmpty { deliver(lines) }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

