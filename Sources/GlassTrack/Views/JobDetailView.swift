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
        .overlay(alignment: .bottom) {
            if job.status == .running {
                GlassProgressBar(value: job.overallProgress, height: 5)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .glassCard(30)
        .animation(.smooth, value: job.status)
    }

    @Namespace private var glassNS

    private var actionButtons: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .trailing, spacing: 10) {
                switch job.status {
                case .running, .idle:
                    Button(role: .destructive) { job.cancel(); if job.status == .idle { store.remove(job) } } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(.red)
                    .glassEffectID("primary", in: glassNS)
                case .finished:
                    if let blend = job.blendURL {
                        Button {
                            NSWorkspace.shared.open(blend)
                        } label: {
                            Label("Open in Blender", systemImage: "cube.transparent.fill")
                                .font(.headline)
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.extraLarge)
                        .glassEffectID("primary", in: glassNS)
                    }
                    HStack(spacing: 10) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([job.projectDir]) } label: {
                            Image(systemName: "folder")
                                .frame(width: 22, height: 22)
                        }
                        .help("Show project files in Finder")
                        .glassEffectID("files", in: glassNS)
                        Button { copyScriptCommand() } label: {
                            Image(systemName: "doc.on.doc")
                                .frame(width: 22, height: 22)
                        }
                        .help("Copy the Blender import command")
                        .glassEffectID("script", in: glassNS)
                        Button { store.retry(job) } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 22, height: 22)
                        }
                        .help("Solve again")
                        .glassEffectID("retry", in: glassNS)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                case .failed, .cancelled:
                    Button { store.retry(job) } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .font(.headline)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.extraLarge)
                    .glassEffectID("primary", in: glassNS)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([job.projectDir]) } label: {
                        Label("Show Files", systemImage: "folder")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .glassEffectID("files", in: glassNS)
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: job.status)
    }

    private func copyScriptCommand() {
        let cmd = "'\(ToolLocator.blender() ?? "blender")' --python '\(job.projectDir.appendingPathComponent(BlenderScript.fileName).path)'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    // MARK: Stages

    private var stageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Pipeline", symbol: "list.bullet.indent",
                         trailing: "\(job.stages.filter { $0.state == .done }.count)/\(job.stages.filter { $0.state != .skipped }.count)")
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            ForEach(Array(job.stages.enumerated()), id: \.element.id) { i, stage in
                StageRow(stage: stage, isLast: i == job.stages.count - 1,
                         nextActive: i + 1 < job.stages.count && job.stages[i + 1].state != .pending)
            }
        }
        .padding(16)
        .glassCard(26)
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
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
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
    var isLast: Bool
    var nextActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline node + connector
            VStack(spacing: 0) {
                node
                if !isLast {
                    Capsule()
                        .fill(stage.state == .done
                              ? AnyShapeStyle(LinearGradient(colors: [.green, nextActive ? .accentColor : .green.opacity(0.4)],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.primary.opacity(0.1)))
                        .frame(width: 2.5)
                        .frame(minHeight: 14)
                        .padding(.vertical, 3)
                }
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stage.id.title)
                        .font(.callout.weight(stage.state == .running ? .bold : .semibold))
                        .foregroundStyle(stage.state == .pending ? .secondary : .primary)
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
                    GlassProgressBar(value: stage.fraction < 0 ? nil : stage.fraction, height: 6)
                        .padding(.vertical, 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
                if !stage.detail.isEmpty || stage.state == .skipped {
                    Text(stage.state == .skipped ? "Skipped" : stage.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            .padding(.vertical, 4)
            .padding(.bottom, isLast ? 0 : 6)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            if stage.state == .running {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .padding(-2)
                    .transition(.opacity)
            }
        }
        .opacity(stage.state == .skipped ? 0.45 : 1)
        .animation(.smooth, value: stage.state)
    }

    private var node: some View {
        ZStack {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(.white.opacity(stage.state == .pending ? 0.08 : 0.3), lineWidth: 0.75))
                .shadow(color: glow, radius: stage.state == .running || stage.state == .done ? 6 : 0)
            icon
        }
        .frame(width: 30, height: 30)
    }

    private var fill: AnyShapeStyle {
        switch stage.state {
        case .done: AnyShapeStyle(LinearGradient(colors: [.green.mix(with: .white, by: 0.2), .green], startPoint: .top, endPoint: .bottom))
        case .running: AnyShapeStyle(LinearGradient(colors: [Color.accentColor.mix(with: .white, by: 0.2), .accentColor], startPoint: .top, endPoint: .bottom))
        case .failed: AnyShapeStyle(Color.red)
        default: AnyShapeStyle(Color.primary.opacity(0.08))
        }
    }

    private var glow: Color {
        switch stage.state {
        case .done: .green.opacity(0.45)
        case .running: Color.accentColor.opacity(0.6)
        default: .clear
        }
    }

    @ViewBuilder private var icon: some View {
        switch stage.state {
        case .done:
            Image(systemName: "checkmark").font(.caption.weight(.heavy)).foregroundStyle(.white)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark").font(.caption.weight(.heavy)).foregroundStyle(.white)
        case .running:
            Image(systemName: stage.id.symbol).font(.caption.weight(.semibold)).foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)
        case .skipped:
            Image(systemName: "minus").font(.caption.weight(.bold)).foregroundStyle(.secondary)
        case .pending:
            Image(systemName: stage.id.symbol).font(.caption).foregroundStyle(.secondary)
        }
    }
}
