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
            .buttonStyle(.liquidGlass(.primary))
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
            .buttonStyle(.liquidGlass(circle: true))
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
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Quality", symbol: "dial.high")
                .padding(.horizontal, 4)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(QualityPreset.allCases) { q in
                        QualityCard(preset: q, selected: job.settings.quality == q) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { job.settings.quality = q }
                        }
                    }
                }
            }
        }
    }

    private var samplingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "Frames", symbol: "film.stack",
                         trailing: "≈ \(job.estimatedFrames) frames to solve")
                .animation(.smooth, value: job.estimatedFrames)

            if job.inputKind == .video {
                GlassSegmented(selection: $job.settings.sampling, options: [
                    DropdownOption(value: .everyNth, title: "Every Nth Frame", symbol: "square.stack.3d.down.right"),
                    DropdownOption(value: .targetFPS, title: "Target FPS", symbol: "speedometer"),
                ])
                .frame(maxWidth: 420)

                Group {
                    if job.settings.sampling == .everyNth {
                        SettingRow(symbol: "forward.frame", color: .blue, title: "Frame step",
                                   subtitle: job.settings.frameStep == 1
                                       ? "Every frame is solved"
                                       : "Solve every \(Self.ordinal(job.settings.frameStep)) frame; keys land on original frame numbers") {
                            GlassStepper(value: $job.settings.frameStep, range: 1...30)
                        }
                    } else {
                        SettingRow(symbol: "speedometer", color: .teal, title: "Sample rate",
                                   subtitle: "Frames per second of footage") {
                            HStack(spacing: 12) {
                                Slider(value: $job.settings.targetFPS, in: 1...30, step: 1)
                                    .frame(width: 180)
                                Text("\(Int(job.settings.targetFPS)) fps")
                                    .monospacedDigit()
                                    .font(.body.weight(.semibold))
                                    .contentTransition(.numericText(value: job.settings.targetFPS))
                                    .frame(width: 56, alignment: .trailing)
                            }
                        }
                    }
                }
                .transition(.blurReplace)
                Hairline()
            }

            SettingRow(symbol: "number", color: .orange, title: "Limit frame count",
                       subtitle: job.settings.maxFrames > 0 ? "Stop after \(job.settings.maxFrames) frames" : "Use the whole clip") {
                HStack(spacing: 12) {
                    if job.settings.maxFrames > 0 {
                        GlassStepper(value: $job.settings.maxFrames, range: 10...5000, step: 50)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Toggle("", isOn: Binding(
                        get: { job.settings.maxFrames > 0 },
                        set: { on in withAnimation(.snappy) { job.settings.maxFrames = on ? 300 : 0 } }))
                        .toggleStyle(.liquidGlass)
                        .labelsHidden()
                }
            }
        }
        .animation(.smooth, value: job.settings.sampling)
        .padding(20)
        .glassCard(26)
    }

    private var advancedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { showAdvanced.toggle() }
            } label: {
                HStack {
                    SectionTitle(title: "Advanced", symbol: "slider.horizontal.3")
                    Image(systemName: "chevron.down")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 180 : 0))
                        .frame(width: 30, height: 30)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(spacing: 4) {
                    SettingRow(symbol: "camera.aperture", color: .indigo, title: "Lens model",
                               subtitle: "How lens distortion is modelled") {
                        GlassDropdown(selection: $job.settings.cameraModel, options: [
                            DropdownOption(value: .simpleRadial, title: "Simple Radial", subtitle: "Recommended for most cameras", symbol: "camera"),
                            DropdownOption(value: .radial, title: "Radial", subtitle: "Two distortion terms", symbol: "camera.metering.center.weighted"),
                            DropdownOption(value: .opencv, title: "OpenCV", subtitle: "Wide-angle & action cams", symbol: "camera.metering.matrix"),
                            DropdownOption(value: .pinhole, title: "Pinhole", subtitle: "No distortion", symbol: "circle.dashed"),
                            DropdownOption(value: .simplePinhole, title: "Simple Pinhole", subtitle: "Single focal, no distortion", symbol: "circle"),
                        ])
                    }
                    Hairline()
                    SettingRow(symbol: "point.3.connected.trianglepath.dotted", color: .purple, title: "Matching",
                               subtitle: "Which frames are compared") {
                        GlassDropdown(selection: $job.settings.matcher, options: [
                            DropdownOption(value: .sequential, title: "Sequential", subtitle: "Neighbouring frames — best for video", symbol: "film"),
                            DropdownOption(value: .exhaustive, title: "Exhaustive", subtitle: "Every pair — unordered photos", symbol: "square.grid.3x3"),
                        ])
                    }
                    Hairline()
                    SettingRow(symbol: "cube.transparent", color: .pink, title: "Solver",
                               subtitle: "Reconstruction strategy") {
                        GlassDropdown(selection: $job.settings.mapper, options: [
                            DropdownOption(value: .incremental, title: "Incremental", subtitle: "Most robust, adds frames one by one", symbol: "plus.square.on.square"),
                            DropdownOption(value: .global, title: "Global (GLOMAP)", subtitle: "Much faster on long shots", symbol: "globe"),
                        ])
                    }
                    Hairline()
                    SettingRow(symbol: "photo", color: .green, title: "Frame quality",
                               subtitle: "JPEG quality of extracted frames") {
                        GlassSegmented(selection: $job.settings.jpegQuality, options: [
                            DropdownOption(value: 2, title: "Max"),
                            DropdownOption(value: 4, title: "High"),
                            DropdownOption(value: 7, title: "Medium"),
                        ])
                        .frame(width: 240)
                    }
                    Hairline()
                    SettingRow(symbol: "camera.fill", color: .blue, title: "Fixed zoom",
                               subtitle: "All frames share one camera") {
                        Toggle("", isOn: $job.settings.singleCamera).toggleStyle(.liquidGlass).labelsHidden()
                    }
                    Hairline()
                    SettingRow(symbol: "rectangle.dashed", color: .cyan, title: "Undistorted frames",
                               subtitle: "Also export lens-corrected images") {
                        Toggle("", isOn: $job.settings.undistort).toggleStyle(.liquidGlass).labelsHidden()
                    }
                    Hairline()
                    SettingRow(symbol: "cube.transparent.fill", color: .orange, title: "Build .blend scene",
                               subtitle: ToolLocator.blender() == nil ? "Blender not installed" : "Camera, point cloud & plate, ready to open") {
                        Toggle("", isOn: $job.settings.buildBlend).toggleStyle(.liquidGlass).labelsHidden()
                            .disabled(ToolLocator.blender() == nil)
                    }
                    Hairline()
                    SettingRow(symbol: "folder.fill", color: .gray, title: "Save to",
                               subtitle: job.outputRoot.path(percentEncoded: false)) {
                        Button("Change…") { chooseOutput() }
                            .buttonStyle(.liquidGlass())
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(20)
        .glassCard(26)
    }

    private var actions: some View {
        HStack(spacing: 14) {
            Label("Runs on all CPU cores · queue as many tracks as you like", systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .cancel, action: onCancel) {
                Text("Cancel").padding(.horizontal, 6)
            }
            .buttonStyle(.liquidGlass())
            .controlSize(.large)

            Button(action: onStart) {
                Label("Start Tracking", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.liquidGlass(.primary))
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(job.videoInfo == nil && job.imageCount == 0)
        }
        .padding(.top, 4)
    }

    static func ordinal(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
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

private struct QualityCard: View {
    let preset: QualityPreset
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: preset.symbol)
                        .font(.title2.weight(.medium))
                        .symbolEffect(.bounce, value: selected)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title).font(.headline)
                    Text(preset.subtitle)
                        .font(.caption)
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .lineLimit(2, reservesSpace: true)
                }
                HStack(spacing: 3) {
                    ForEach(0..<4) { i in
                        Capsule()
                            .fill(i <= QualityPreset.allCases.firstIndex(of: preset)!
                                  ? (selected ? Color.white : Color.accentColor)
                                  : Color.primary.opacity(0.12))
                            .frame(height: 4)
                    }
                }
            }
            .foregroundStyle(selected ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .contentShape(.rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(Color.accentColor.opacity(0.38)).interactive() : .regular.interactive(),
                     in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(selected ? 0.3 : 0.08), lineWidth: selected ? 1 : 0.75))
        .shadow(color: selected ? Color.accentColor.opacity(0.35) : .clear, radius: 16, y: 6)
        .scaleEffect(hover && !selected ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        .onHover { hover = $0 }
    }
}
