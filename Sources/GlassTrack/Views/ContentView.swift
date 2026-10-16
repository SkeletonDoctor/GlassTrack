import SwiftUI

struct ContentView: View {
    @Environment(JobStore.self) private var store
    @Environment(Toolchain.self) private var toolchain
    @State private var showSetup = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            ZStack {
                AmbientBackground(image: store.selectedJob?.thumbnail)
                Group {
                    if !toolchain.isReady {
                        SetupView()
                    } else if let job = store.selectedJob {
                        JobDetailView(job: job)
                            .id(job.id)
                    } else {
                        NewTrackView()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
            .animation(.smooth, value: store.selection)
        }
        .onAppear { toolchain.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.selection = nil
                } label: {
                    Label("New Track", systemImage: "plus")
                }
                .help("New camera track (⌘N)")
            }
        }
    }
}

struct SidebarView: View {
    @Environment(JobStore.self) private var store
    @Environment(Toolchain.self) private var toolchain

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        store.selection = nil
                    } label: {
                        Label("New Track", systemImage: "plus.viewfinder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.liquidGlass(store.selection == nil ? .primary : .secondary))
                    .padding(.bottom, 10)

                    Text("Tracks")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)

                    if store.jobs.isEmpty {
                        Text("No tracks yet")
                            .foregroundStyle(.tertiary)
                            .font(.callout)
                            .padding(.leading, 6)
                    }
                    ForEach(store.jobs) { job in
                        let selected = store.selection == job.id
                        Button {
                            withAnimation(.smooth) { store.selection = job.id }
                        } label: {
                            JobRow(job: job, selected: selected)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .contentShape(.rect(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        .glassEffect(selected ? .regular.tint(Color.accentColor.opacity(0.35)).interactive()
                                              : .regular.interactive(),
                                     in: .rect(cornerRadius: 16, style: .continuous))
                        .contextMenu {
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.projectDir]) }
                            if job.status == .running {
                                Button("Cancel") { job.cancel() }
                            }
                            Divider()
                            Button("Remove from List", role: .destructive) { store.remove(job) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            ToolStatusFooter()
                .padding(12)
        }
    }
}

private struct JobRow: View {
    let job: TrackJob
    var selected = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let img = job.thumbnail {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: job.inputKind == .video ? "film" : "photo.stack")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 30)
            .clipShape(.rect(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(job.name).lineLimit(1).font(.callout.weight(.semibold))
                    .foregroundStyle(selected ? .white : .primary)
                    .shadow(color: selected ? .black.opacity(0.25) : .clear, radius: 1, y: 0.5)
                if job.status == .running {
                    Text("Tracking · \(Int(job.overallProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .contentTransition(.numericText())
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(job.status.color).frame(width: 6, height: 6)
                        Text(job.status == .idle ? "Queued" : job.status.label)
                            .font(.caption)
                            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    }
                }
            }
            Spacer(minLength: 0)
            if job.status == .running {
                ProgressRing(progress: job.overallProgress, lineWidth: 3, tint: selected ? .white : .accentColor)
                    .frame(width: 20, height: 20)
                    .padding(.trailing, 2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ToolStatusFooter: View {
    @Environment(Toolchain.self) private var toolchain

    var body: some View {
        HStack(spacing: 10) {
            ForEach([Toolchain.Tool.colmap, .ffmpeg, .blender]) { tool in
                let ok = toolchain.isInstalled(tool)
                Label(tool.title, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(ok ? Color.green : (tool.required ? .red : .secondary))
                    .font(.caption2.weight(.medium))
                    .labelStyle(.titleAndIcon)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}
