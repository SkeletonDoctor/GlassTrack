import SwiftUI

/// First-run screen: checks for COLMAP / FFmpeg / Blender and installs whatever is missing.
struct SetupView: View {
    @Environment(Toolchain.self) private var toolchain
    @State private var includeBlender = true
    @State private var installTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.tint)
                        .symbolEffect(.bounce, value: toolchain.installing)
                    Text("Set Up Your Toolchain")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("GlassTrack drives COLMAP and FFmpeg in the background. Missing tools are downloaded and installed for you.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 520)
                }
                .padding(.top, 20)

                GlassEffectContainer(spacing: 10) {
                    VStack(spacing: 10) {
                        ForEach(Toolchain.Tool.allCases) { tool in
                            ToolRow(tool: tool, path: toolchain.paths[tool], includeBlender: $includeBlender)
                        }
                    }
                }
                .frame(maxWidth: 620)

                if toolchain.installing || !toolchain.log.isEmpty {
                    installLog.frame(maxWidth: 620)
                }

                if let err = toolchain.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: 620, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button("Check Again") { toolchain.refresh() }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(toolchain.installing)
                    if toolchain.installing {
                        Button("Stop") { installTask?.cancel() }
                            .buttonStyle(.glass)
                            .controlSize(.large)
                    } else {
                        Button {
                            installTask = Task { await toolchain.installMissing(includeBlender: includeBlender) }
                        } label: {
                            Label("Install Missing Tools", systemImage: "arrow.down.circle.fill")
                                .font(.headline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                    }
                }

                if toolchain.paths[.homebrew] == nil {
                    Text("Homebrew isn't installed yet. Its official installer will open in Terminal and ask for your Mac password once; GlassTrack continues automatically when it finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }

    private var installLog: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if toolchain.installing { ProgressView().controlSize(.small) }
                Text(toolchain.installing ? toolchain.currentStep : "Finished")
                    .font(.callout.weight(.medium))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(toolchain.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 180)
                .background(.black.opacity(0.18), in: .rect(cornerRadius: 12))
                .onChange(of: toolchain.log.count) { proxy.scrollTo(toolchain.log.count - 1, anchor: .bottom) }
            }
        }
        .padding(16)
        .glassCard(22)
    }
}

private struct ToolRow: View {
    let tool: Toolchain.Tool
    let path: String?
    @Binding var includeBlender: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tool.symbol)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title).font(.headline)
                Text(path ?? tool.subtitle)
                    .font(path == nil ? .caption : .caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if path != nil {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            } else if tool == .blender {
                Toggle("Install", isOn: $includeBlender).toggleStyle(.switch)
            } else {
                Label("Missing", systemImage: "arrow.down.circle")
                    .foregroundStyle(.orange)
                    .font(.callout.weight(.medium))
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct SettingsView: View {
    @Environment(JobStore.self) private var store
    @Environment(Toolchain.self) private var toolchain
    @AppStorage(ToolLocator.colmapKey) private var colmapPath = ""
    @AppStorage(ToolLocator.ffmpegKey) private var ffmpegPath = ""
    @AppStorage(ToolLocator.ffprobeKey) private var ffprobePath = ""
    @AppStorage(ToolLocator.blenderKey) private var blenderPath = ""

    var body: some View {
        TabView {
            Form {
                Section("Tool locations (leave empty to auto-detect)") {
                    pathField("COLMAP", $colmapPath, detected: ToolLocator.colmap())
                    pathField("FFmpeg", $ffmpegPath, detected: ToolLocator.ffmpeg())
                    pathField("FFprobe", $ffprobePath, detected: ToolLocator.ffprobe())
                    pathField("Blender", $blenderPath, detected: ToolLocator.blender())
                }
                Section {
                    Button("Install / Update Missing Tools…") {
                        Task { await toolchain.installMissing(includeBlender: true) }
                    }
                    .disabled(toolchain.installing)
                    if toolchain.installing { Text(toolchain.currentStep).font(.caption) }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

            Form {
                Section("Output") {
                    LabeledContent("Projects folder") {
                        HStack {
                            Text(store.outputRoot.path(percentEncoded: false)).lineLimit(1).truncationMode(.head)
                            Button("Change…") {
                                let p = NSOpenPanel()
                                p.canChooseDirectories = true
                                p.canChooseFiles = false
                                p.canCreateDirectories = true
                                if p.runModal() == .OK, let u = p.url { store.outputRoot = u }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 360)
        .onChange(of: [colmapPath, ffmpegPath, ffprobePath, blenderPath]) { toolchain.refresh() }
    }

    private func pathField(_ label: String, _ binding: Binding<String>, detected: String?) -> some View {
        LabeledContent(label) {
            HStack {
                TextField("", text: binding, prompt: Text(detected ?? "Not found"))
                    .textFieldStyle(.roundedBorder)
                Image(systemName: detected != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(detected != nil ? .green : .red)
            }
        }
    }
}
