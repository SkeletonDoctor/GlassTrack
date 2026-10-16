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
        @Bindable var store = store
        List(selection: $store.selection) {
            Section {
                Button {
                    store.selection = nil
                } label: {
                    Label("New Track", systemImage: "plus.viewfinder")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }

            Section("Tracks") {
                if store.jobs.isEmpty {
                    Text("No tracks yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(store.jobs) { job in
                    JobRow(job: job)
                        .tag(job.id)
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
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            ToolStatusFooter()
                .padding(12)
        }
    }
}

private struct JobRow: View {
    let job: TrackJob

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
                Text(job.name).lineLimit(1).font(.callout.weight(.medium))
                if job.status == .running {
                    ProgressView(value: job.overallProgress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(job.status.color).frame(width: 6, height: 6)
                        Text(job.status == .idle ? "Queued" : job.status.label)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
