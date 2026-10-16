import SwiftUI
import UniformTypeIdentifiers

struct NewTrackView: View {
    @Environment(JobStore.self) private var store
    @State private var draft: TrackJob?
    @State private var targeted = false
    @State private var showImporter = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if let draft {
                    DraftEditor(job: draft, onCancel: { withAnimation(.smooth) { self.draft = nil } }) {
                        draft.settings.frameStep = max(1, draft.settings.frameStep)
                        store.enqueue(draft)
                        self.draft = nil
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    dropZone
                        .transition(.opacity)
                }
            }
            .padding(32)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: consumePending)
        .onChange(of: store.pendingOpen) { consumePending() }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .folder]) { result in
            if case .success(let url) = result { load(url) }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("New Camera Track")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Drop footage, pick a quality, get a solved camera in Blender.")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    private var dropZone: some View {
        VStack(spacing: 18) {
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 56, weight: .light))
                .symbolEffect(.bounce, value: targeted)
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Drop a video or a folder of photos")
                    .font(.title2.weight(.semibold))
                Text("MP4 · MOV · ProRes · image sequences (JPG / PNG / TIFF)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                showImporter = true
            } label: {
                Label("Choose File…", systemImage: "folder")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 340)
        .glassEffect(.regular.tint(targeted ? Color.accentColor.opacity(0.25) : .clear).interactive(),
                     in: .rect(cornerRadius: 32))
        .overlay {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .foregroundStyle(targeted ? Color.accentColor : .primary.opacity(0.15))
                .padding(10)
        }
        .scaleEffect(targeted ? 1.015 : 1)
        .animation(.bouncy, value: targeted)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            load(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func consumePending() {
        if let url = store.pendingOpen {
            store.pendingOpen = nil
            load(url)
        }
    }

    private func load(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        let job = TrackJob(input: url, settings: store.defaultSettings, outputRoot: store.outputRoot)
        if job.inputKind == .imageFolder { job.settings.sampling = .everyNth }
        withAnimation(.smooth) { draft = job }
        Task { await job.loadInputPreview() }
    }
}

// MARK: - Draft editor

private struct DraftEditor: View {
    @Bindable var job: TrackJob
    var onCancel: () -> Void
    var onStart: () -> Void
    @State private var showAdvanced = false
    @Environment(JobStore.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            sourceCard
            qualityPicker
            samplingCard
            advancedCard
            actions
        }
    }

    private var sourceCard: some View {
        HStack(spacing: 18) {
            ZStack {
                if let img = job.thumbnail {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 220, height: 124)
            .clipShape(.rect(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 10) {
                Text(job.inputURL.lastPathComponent)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let v = job.videoInfo {
                    FlowChips(items: chips(v))
                } else {
                    Text("Reading media…").foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(role: .cancel, action: onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Choose different footage")
        }
        .padding(16)
        .glassCard(26)
    }

    private func chips(_ v: VideoInfo) -> [(String, String)] {
        var c: [(String, String)] = [("aspectratio", "\(v.width)×\(v.height)")]
        if job.inputKind == .video {
            c.append(("speedometer", String(format: "%.3g fps", v.fps)))
            c.append(("film.stack", "\(v.frameCount) frames"))
            c.append(("clock", TrackJob.format(v.duration)))
        } else {
            c.append(("photo.stack", "\(job.imageCount) photos"))
        }
        return c
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quality").font(.headline).padding(.leading, 4)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(QualityPreset.allCases) { q in
                        let selected = job.settings.quality == q
                        Button {
                            withAnimation(.bouncy) { job.settings.quality = q }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: q.symbol)
                                    .font(.title2)
                                    .foregroundStyle(selected ? Color.white : Color.accentColor)
                                Text(q.title).font(.headline)
                                Text(q.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
                                    .lineLimit(2, reservesSpace: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selected ? .white : .primary)
                        .glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                                     in: .rect(cornerRadius: 20))
                    }
                }
            }
        }
    }

    private var samplingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Frames", systemImage: "film.stack").font(.headline)
                Spacer()
                Text("≈ \(job.estimatedFrames) frames to solve")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: job.estimatedFrames)
            }
            if job.inputKind == .video {
                Picker("Sampling", selection: $job.settings.sampling) {
                    ForEach(FrameSampling.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if job.settings.sampling == .everyNth {
                    HStack {
                        Text("Use every")
                        Stepper(value: $job.settings.frameStep, in: 1...30) {
                            Text("\(job.settings.frameStep)").monospacedDigit().bold()
                        }
                        Text(job.settings.frameStep == 1 ? "frame (all)" : "frames")
                        Spacer()
                        Text("Keyframes are placed on the original frame numbers.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text("Target")
                        Slider(value: $job.settings.targetFPS, in: 1...30, step: 1)
                        Text("\(Int(job.settings.targetFPS)) fps").monospacedDigit().frame(width: 52)
                    }
                }
            }
            HStack {
                Toggle("Limit frame count", isOn: Binding(
                    get: { job.settings.maxFrames > 0 },
                    set: { job.settings.maxFrames = $0 ? 300 : 0 }))
                if job.settings.maxFrames > 0 {
                    Stepper(value: $job.settings.maxFrames, in: 10...5000, step: 50) {
                        Text("\(job.settings.maxFrames) max").monospacedDigit()
                    }
                }
                Spacer()
            }
        }
        .padding(18)
        .glassCard(24)
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.smooth) { showAdvanced.toggle() }
            } label: {
                HStack {
                    Label("Advanced", systemImage: "slider.horizontal.3").font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showAdvanced {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Text("Lens model").foregroundStyle(.secondary)
                        Picker("", selection: $job.settings.cameraModel) {
                            ForEach(CameraModel.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Matching").foregroundStyle(.secondary)
                        Picker("", selection: $job.settings.matcher) {
                            ForEach(MatcherKind.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("Solver").foregroundStyle(.secondary)
                        Picker("", selection: $job.settings.mapper) {
                            ForEach(MapperKind.allCases) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                    GridRow {
                        Text("JPEG quality").foregroundStyle(.secondary)
                        Picker("", selection: $job.settings.jpegQuality) {
                            Text("Maximum").tag(2); Text("High").tag(4); Text("Medium").tag(7)
                        }.labelsHidden().pickerStyle(.segmented)
                    }
                    GridRow {
                        Text("Options").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Same camera for all frames (fixed zoom)", isOn: $job.settings.singleCamera)
                            Toggle("Export undistorted frames", isOn: $job.settings.undistort)
                            Toggle("Build .blend scene automatically", isOn: $job.settings.buildBlend)
                                .disabled(ToolLocator.blender() == nil)
                        }
                    }
                    GridRow {
                        Text("Output").foregroundStyle(.secondary)
                        HStack {
                            Text(job.outputRoot.path(percentEncoded: false))
                                .lineLimit(1).truncationMode(.head)
                                .font(.callout.monospaced())
                            Button("Change…") { chooseOutput() }
                                .buttonStyle(.glass)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(18)
        .glassCard(24)
    }

    private var actions: some View {
        HStack {
            Text("Runs COLMAP on all CPU cores. You can queue more tracks while this one solves.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onStart) {
                Label("Start Tracking", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(job.videoInfo == nil && job.imageCount == 0)
        }
        .padding(.top, 4)
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            job.outputRoot = url
            store.outputRoot = url
        }
    }
}

/// Simple wrapping row of chips.
private struct FlowChips: View {
    let items: [(String, String)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.1) { InfoChip(symbol: $0.0, text: $0.1) }
        }
    }
}
