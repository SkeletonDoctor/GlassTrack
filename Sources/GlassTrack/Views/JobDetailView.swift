import SwiftUI

struct JobDetailView: View {
    @Bindable var job: TrackJob
    @Environment(JobStore.self) private var store
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                HStack(alignment: .top, spacing: 20) {
                    stageList
                        .frame(width: 330)
                    VStack(spacing: 20) {
                        preview
                        if let s = job.stats { statsGrid(s) }
                    }
                }
                logPanel
            }
            .padding(28)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 22) {
            ZStack {
                ProgressRing(progress: job.status == .finished ? 1 : job.overallProgress,
                             lineWidth: 9,
                             tint: job.status == .finished ? .green : .accentColor)
                if job.status == .finished {
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(Int(job.overallProgress * 100))%")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .frame(width: 92, height: 92)
            .animation(.bouncy, value: job.status)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(job.name).font(.system(size: 28, weight: .bold, design: .rounded)).lineLimit(1)
                    StatusPill(status: job.status)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack(spacing: 14) {
                        if let st = job.currentStage {
                            Label(st.id.title, systemImage: st.id.symbol)
                        }
                        Label(TrackJob.format(job.elapsed), systemImage: "timer")
                        if let eta = job.eta {
                            Label("~\(TrackJob.format(eta)) left", systemImage: "hourglass")
                        }
                        Label(job.settings.quality.title, systemImage: job.settings.quality.symbol)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                if case .failed(let msg) = job.status {
                    Text(msg).font(.callout).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            actionButtons
        }
        .padding(20)
        .glassCard(30)
    }

    private var actionButtons: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .trailing, spacing: 10) {
                switch job.status {
                case .running, .idle:
                    Button(role: .destructive) { job.cancel(); if job.status == .idle { store.remove(job) } } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .buttonStyle(.glass)
                case .finished:
                    if let blend = job.blendURL {
                        Button {
                            NSWorkspace.shared.open(blend)
                        } label: {
                            Label("Open in Blender", systemImage: "cube.transparent.fill")
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }
                    HStack {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([job.projectDir]) } label: {
                            Label("Show Files", systemImage: "folder")
                        }
                        Button { copyScriptCommand() } label: {
                            Label("Copy Script", systemImage: "doc.on.doc")
                        }
                        .help("Copies the Blender import command for this track")
                    }
                    .buttonStyle(.glass)
                case .failed, .cancelled:
                    Button { store.retry(job) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                        .buttonStyle(.glassProminent)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([job.projectDir]) } label: {
                        Label("Show Files", systemImage: "folder")
                    }
                    .buttonStyle(.glass)
                }
            }
        }
    }

    private func copyScriptCommand() {
        let cmd = "'\(ToolLocator.blender() ?? "blender")' --python '\(job.projectDir.appendingPathComponent(BlenderScript.fileName).path)'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    // MARK: Stages

    private var stageList: some View {
        VStack(spacing: 10) {
            ForEach(job.stages) { stage in
                StageRow(stage: stage)
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            if let model = job.model {
                PointCloudView(model: model)
                    .clipShape(.rect(cornerRadius: 22))
                    .overlay(alignment: .topLeading) {
                        Label("Drag to orbit · scroll to zoom", systemImage: "rotate.3d")
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)
                            .padding(12)
                    }
            } else if let img = job.thumbnail {
                Color.clear
                    .overlay {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipShape(.rect(cornerRadius: 22))
                    .overlay {
                        if job.status == .running {
                            VStack(spacing: 10) {
                                ProgressView().controlSize(.large)
                                Text(job.currentStage?.detail.isEmpty == false ? job.currentStage!.detail : "Working…")
                                    .font(.callout.weight(.medium))
                                    .contentTransition(.numericText())
                            }
                            .padding(18)
                            .glassCard(18)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 360)
        .padding(6)
        .glassCard(28)
    }

    private func statsGrid(_ s: SolveStats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            StatTile(value: "\(s.registeredImages)/\(s.totalImages)", label: "Frames solved", symbol: "camera.fill")
            StatTile(value: s.points.formatted(), label: "3D points", symbol: "circle.grid.3x3.fill")
            StatTile(value: s.meanReprojectionError.map { String(format: "%.2f px", $0) } ?? "–",
                     label: "Reprojection error", symbol: "scope")
            StatTile(value: s.meanTrackLength.map { String(format: "%.1f", $0) } ?? "–",
                     label: "Avg. track length", symbol: "point.topleft.down.to.point.bottomright.curvepath")
        }
    }

    // MARK: Log

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.smooth) { showLog.toggle() }
            } label: {
                HStack {
                    Label("Console", systemImage: "terminal").font(.headline)
                    Text(job.log.last.map(TrackJob.cleanLog) ?? "")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showLog ? 180 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(job.log.suffix(1500).enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix("──") ? Color.accentColor :
                                                     line.hasPrefix("✗") || line.contains("rror") ? .red : .primary.opacity(0.85))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                            }
                        }
                        .padding(10)
                    }
                    .frame(height: 260)
                    .background(.black.opacity(0.18), in: .rect(cornerRadius: 14))
                    .onChange(of: job.log.count) {
                        proxy.scrollTo(min(job.log.count, 1500) - 1, anchor: .bottom)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(18)
        .glassCard(24)
    }
}

private struct StageRow: View {
    let stage: StageProgress

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(stage.state == .pending ? 0.08 : 0.2))
                icon
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(stage.id.title).font(.callout.weight(.semibold))
                    Spacer()
                    if let s = stage.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(TrackJob.format((stage.finishedAt ?? Date()).timeIntervalSince(s)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if stage.state == .running {
                    if stage.fraction < 0 {
                        ProgressView().progressViewStyle(.linear)
                    } else {
                        ProgressView(value: stage.fraction).progressViewStyle(.linear)
                            .animation(.smooth, value: stage.fraction)
                    }
                }
                if !stage.detail.isEmpty || stage.state == .skipped {
                    Text(stage.state == .skipped ? "Skipped" : stage.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
        }
        .padding(12)
        .opacity(stage.state == .skipped ? 0.5 : 1)
        .glassEffect(stage.state == .running ? .regular.tint(.accentColor.opacity(0.15)) : .regular,
                     in: .rect(cornerRadius: 18))
        .animation(.smooth, value: stage.state)
    }

    private var color: Color {
        switch stage.state {
        case .done: .green
        case .running: .accentColor
        case .failed: .red
        default: .secondary
        }
    }

    @ViewBuilder private var icon: some View {
        switch stage.state {
        case .done:
            Image(systemName: "checkmark").font(.callout.bold()).foregroundStyle(.green)
                .transition(.scale)
        case .failed:
            Image(systemName: "exclamationmark").font(.callout.bold()).foregroundStyle(.red)
        case .running:
            Image(systemName: stage.id.symbol).foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, options: .repeating)
        default:
            Image(systemName: stage.id.symbol).foregroundStyle(.secondary)
        }
    }
}
