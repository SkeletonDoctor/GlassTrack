import Charts
import SwiftUI

/// The job screen. Each section is its own view that reads only what it shows, so the
/// frequent progress updates of a running solve redraw those sections and nothing else.
/// (When this was one big view, every update rebuilt the Stop button and clicks on it
/// could be lost for many seconds.)
struct JobDetailView: View {
    let job: TrackJob

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HeaderCard(job: job)
                    .overlay(alignment: .trailing) {
                        JobActionButtons(job: job)
                            .padding(.trailing, 20)
                    }
                HStack(alignment: .top, spacing: 20) {
                    StageListCard(job: job)
                        .frame(width: 330)
                    VStack(spacing: 20) {
                        PreviewCard(job: job)
                        StatsSection(job: job)
                        QualitySection(job: job)
                        ExportsSection(job: job)
                    }
                }
                LogPanel(job: job)
            }
            .padding(28)
        }
        .scrollContentBackground(.hidden)
    }
}

private struct HeaderCard: View {
    let job: TrackJob

    var body: some View {
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
        }
        .padding(20)
        .padding(.trailing, 250)   // room for the buttons layered on top
        .glassCard(30)
        .animation(.smooth, value: job.status)
    }
}

private struct StageListCard: View {
    let job: TrackJob

    var body: some View {
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
}

private struct PreviewCard: View {
    let job: TrackJob

    var body: some View {
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
}

private struct StatsSection: View {
    let job: TrackJob

    var body: some View {
        if let s = job.stats {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
            StatTile(value: "\(s.registeredImages)/\(s.totalImages)", label: "Frames solved", symbol: "camera.fill")
            StatTile(value: s.points.formatted(), label: "3D points", symbol: "circle.grid.3x3.fill")
            StatTile(value: s.meanReprojectionError.map { String(format: "%.2f px", $0) } ?? "–",
                     label: "Reprojection error", symbol: "scope")
            StatTile(value: s.meanTrackLength.map { String(format: "%.1f", $0) } ?? "–",
                     label: "Avg. track length", symbol: "point.topleft.down.to.point.bottomright.curvepath")
        }
        }
    }
}

/// Per-frame reprojection error, with frames that failed to solve marked in red.
private struct QualitySection: View {
    let job: TrackJob

    var body: some View {
        if job.status == .finished {
            let q = job.frameQuality
            if !q.isEmpty {
                let solved = q.compactMap(\.error)
                let failed = q.filter { $0.error == nil }
                let mean = solved.isEmpty ? 0 : solved.reduce(0, +) / Double(solved.count)
                let rating = Self.rating(mean: mean, solvedFraction: Double(solved.count) / Double(q.count))
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionTitle(title: "Solve Quality", symbol: "waveform.path.ecg")
                        Label(rating.0, systemImage: rating.2)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(rating.1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .glassEffect(.regular.tint(rating.1.opacity(0.2)), in: .capsule)
                    }
                    Chart {
                        ForEach(q) { f in
                            if let e = f.error {
                                AreaMark(x: .value("Frame", f.frame), y: .value("Error (px)", e))
                                    .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), .clear],
                                                                    startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.monotone)
                                LineMark(x: .value("Frame", f.frame), y: .value("Error (px)", e))
                                    .foregroundStyle(Color.accentColor)
                                    .interpolationMethod(.monotone)
                            } else {
                                RuleMark(x: .value("Frame", f.frame))
                                    .foregroundStyle(.red.opacity(0.55))
                                    .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                        RuleMark(y: .value("Mean", mean))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text(String(format: "mean %.2f px", mean)).font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                    .chartXAxisLabel("Frame")
                    .chartYAxisLabel("px")
                    .frame(height: 150)
                    if !failed.isEmpty {
                        Label("\(failed.count) frame\(failed.count == 1 ? "" : "s") didn't solve (red). The camera is interpolated across them in Blender.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if let worst = q.max(by: { ($0.error ?? 0) < ($1.error ?? 0) }), let e = worst.error {
                        Text(String(format: "Every frame solved. Highest error %.2f px at frame %d.", e, worst.frame))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                .glassCard(24)
            }
        }
    }

    static func rating(mean: Double, solvedFraction: Double) -> (String, Color, String) {
        if solvedFraction < 0.7 { return ("Partial", .orange, "exclamationmark.triangle") }
        switch mean {
        case ..<0.6: return ("Excellent", .green, "checkmark.seal.fill")
        case ..<1.0: return ("Good", .green, "checkmark.circle.fill")
        case ..<2.0: return ("Fair", .yellow, "circle.lefthalf.filled")
        default: return ("Poor", .red, "xmark.octagon.fill")
        }
    }
}

/// Camera exports for other apps, written next to the .blend.
private struct ExportsSection: View {
    let job: TrackJob

    private struct Item: Identifiable {
        let url: URL
        var id: URL { url }
        var info: (title: String, app: String, symbol: String) {
            switch url.pathExtension.lowercased() {
            case "fbx": ("FBX", "Maya · C4D · Unreal · Unity", "cube")
            case "abc": ("Alembic", "Houdini · Maya · C4D", "circle.hexagongrid")
            case "jsx": ("After Effects", "File › Scripts › Run Script File", "sparkles.tv")
            case "nk": ("Nuke Camera", "Paste into a Nuke script", "camera.aperture")
            case "chan": ("Nuke .chan", "Camera › Import chan file", "list.number")
            default: (url.pathExtension.uppercased(), "", "doc")
            }
        }
    }

    var body: some View {
        if job.status == .finished {
            let dir = job.projectDir.appendingPathComponent("exports", isDirectory: true)
            let order = ["jsx", "fbx", "abc", "nk", "chan"]
            let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { order.contains($0.pathExtension.lowercased()) }
                .sorted { order.firstIndex(of: $0.pathExtension.lowercased())! < order.firstIndex(of: $1.pathExtension.lowercased())! }
                .map(Item.init)
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "Exports", symbol: "square.and.arrow.up")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                        ForEach(items) { item in
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([item.url])
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: item.info.symbol)
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                        .frame(width: 26)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.info.title).font(.callout.weight(.semibold))
                                        Text(item.info.app).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
                                }
                                .padding(12)
                                .contentShape(.rect(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16, style: .continuous))
                            .help("Show \(item.url.lastPathComponent) in Finder")
                        }
                    }
                }
                .padding(18)
                .glassCard(24)
            }
        }
    }
}

private struct LogPanel: View {
    let job: TrackJob
    @State private var showLog = false

    var body: some View {
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
                    Image(systemName: "chevron.down")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showLog ? 180 : 0))
                        .frame(width: 30, height: 30)
                        .glassEffect(.regular.interactive(), in: .circle)
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
                    if stage.state == .running && stage.fraction >= 0 {
                        Text("\(Int(stage.fraction * 100))%")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.tint)
                            .contentTransition(.numericText())
                    }
                    if let s = stage.startedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(TrackJob.format((stage.finishedAt ?? Date()).timeIntervalSince(s)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
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
            .padding(.vertical, 4)
            .padding(.bottom, isLast ? 0 : 6)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background {
            if stage.state == .running {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.14)), in: .rect(cornerRadius: 16, style: .continuous))
                    .padding(-2)
                    .transition(.opacity)
            }
        }
        .opacity(stage.state == .skipped ? 0.45 : 1)
        .animation(.smooth, value: stage.state)
    }

    private var node: some View {
        ZStack {
            if stage.state == .running {
                ProgressRing(progress: stage.fraction, lineWidth: 3)
                    .frame(width: 38, height: 38)
                    .transition(.scale.combined(with: .opacity))
            }
            Circle()
                .fill(.clear)
                .glassEffect(nodeGlass, in: .circle)
                .overlay(Circle().fill(wash))
                .overlay(Circle().strokeBorder(.white.opacity(stage.state == .pending ? 0.08 : 0.25), lineWidth: 0.75))
                .shadow(color: glow, radius: stage.state == .running || stage.state == .done ? 6 : 0)
            icon
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
        .frame(width: 30, height: 30)
    }

    private var nodeGlass: Glass {
        switch stage.state {
        case .done: .regular.tint(Color.green.opacity(0.6))
        case .running: .regular.tint(Color.accentColor.opacity(0.65))
        case .failed: .regular.tint(Color.red.opacity(0.6))
        default: .regular
        }
    }

    /// Keeps the state colour visible when the window is inactive and glass tints fade.
    private var wash: Color {
        switch stage.state {
        case .done: .green.opacity(0.3)
        case .running: Color.accentColor.opacity(0.3)
        case .failed: .red.opacity(0.3)
        default: .clear
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

/// Header buttons. Kept in their own view so the frequent progress updates of a running
/// solve don't redraw them (which could swallow a click on Stop).
private struct JobActionButtons: View {
    let job: TrackJob
    @Environment(JobStore.self) private var store

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
                switch job.status {
                case .running, .idle:
                    Button(role: .destructive) { job.cancel(); if job.status == .idle { store.remove(job) } } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.liquidGlass(.destructive))
                    .controlSize(.large)
                case .finished:
                    if let blend = job.blendURL {
                        Button {
                            NSWorkspace.shared.open(blend)
                        } label: {
                            Label("Open in Blender", systemImage: "cube.transparent.fill")
                                .font(.headline)
                                .padding(.horizontal, 8)
                        }
                        .buttonStyle(.liquidGlass(.primary))
                        .controlSize(.extraLarge)
                    }
                    HStack(spacing: 10) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([job.projectDir]) } label: {
                            Image(systemName: "folder")
                                .frame(width: 22, height: 22)
                        }
                        .help("Show project files in Finder")
                        Button { copyScriptCommand() } label: {
                            Image(systemName: "doc.on.doc")
                                .frame(width: 22, height: 22)
                        }
                        .help("Copy the Blender import command")
                        Button { store.retry(job, fromScratch: true) } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 22, height: 22)
                        }
                        .help("Solve again")
                    }
                    .buttonStyle(.liquidGlass(circle: true))
                    .controlSize(.large)
                case .failed, .cancelled:
                    Button { store.retry(job) } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .font(.headline)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.liquidGlass(.primary))
                    .controlSize(.extraLarge)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([job.projectDir]) } label: {
                        Label("Show Files", systemImage: "folder")
                    }
                    .buttonStyle(.liquidGlass())
                }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: job.status)
    }

    private func copyScriptCommand() {
        let cmd = "'\(ToolLocator.blender() ?? "blender")' --python '\(job.projectDir.appendingPathComponent(BlenderScript.fileName).path)'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }
}
