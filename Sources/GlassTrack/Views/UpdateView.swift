import SwiftUI

/// Sidebar pill shown while a newer release is waiting.
struct UpdateBanner: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        if let release = updater.offered {
            Button {
                updater.showSheet = true
            } label: {
                HStack(spacing: 8) {
                    if updater.phase == .downloading || updater.phase == .installing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle.fill").font(.title3)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Update available").font(.caption.weight(.semibold))
                        Text("GlassTrack \(release.version)").font(.caption2).opacity(0.85)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Color.accentColor.opacity(0.7)).interactive(), in: .capsule)
            .help("See what's new and install it")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Release notes with Install / Later, and the result of a manual "Check for Updates…".
struct UpdateSheet: View {
    @Environment(Updater.self) private var updater
    @Environment(JobStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.title2.weight(.bold))
                    Text(subhead).font(.callout).foregroundStyle(.secondary)
                }
            }

            if showsNotes, let release = updater.latest {
                ScrollView {
                    ReleaseNotes(markdown: release.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .frame(height: 260)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12))
            }

            if case .failed(let message) = updater.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if showsNotes, let blocker = updater.installBlocker {
                Label(blocker, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if showsNotes, store.jobs.contains(where: { $0.status == .running }) {
                Label("A solve is running. It will pick up where it left off after the relaunch.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if showsNotes, let release = updater.latest {
                    Button("Skip This Version") { updater.skipOffered() }
                        .disabled(updater.isBusy)
                    Link("View on GitHub", destination: release.pageURL)
                        .font(.callout)
                }
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 540)
        .animation(.smooth, value: updater.phase)
    }

    private var showsNotes: Bool {
        guard updater.latest != nil else { return false }
        switch updater.phase {
        case .available, .downloading, .installing: return true
        case .failed: return updater.offered != nil
        default: return false
        }
    }

    private var headline: String {
        switch updater.phase {
        case .checking: "Checking for updates…"
        case .upToDate, .idle: "You're up to date"
        case .available, .failed: updater.offered.map { "GlassTrack \($0.version) is available" } ?? "Update check failed"
        case .downloading: "Downloading GlassTrack \(updater.latest?.version ?? "")…"
        case .installing: "Installing…"
        }
    }

    private var subhead: String {
        switch updater.phase {
        case .checking: "Asking GitHub for the latest release."
        case .upToDate, .idle: "GlassTrack \(Updater.currentVersion) is the newest version."
        default: "You have \(Updater.currentVersion)."
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updater.phase {
        case .checking:
            ProgressView().controlSize(.small)
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        case .downloading, .installing:
            ProgressView().controlSize(.small)
            Button("Hide") { dismiss() }.keyboardShortcut(.cancelAction)
        case .available:
            installButtons
        case .failed where updater.offered != nil:
            installButtons
        default:
            Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private var installButtons: some View {
            Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
            if updater.installBlocker == nil, updater.latest?.zipURL != nil {
                Button(updater.phase == .available ? "Install and Relaunch" : "Try Again") {
                    Task { await updater.installAndRelaunch() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            } else if let page = updater.latest?.pageURL {
                Button("Download from GitHub") { NSWorkspace.shared.open(page); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
    }
}

/// Light renderer for GitHub release notes: headings, bullets and inline styles.
private struct ReleaseNotes: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("#") {
                    Text(inline(String(line.drop { $0 == "#" || $0 == " " })))
                        .font(.headline)
                        .padding(.top, 6)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(String(line.dropFirst(2))))
                    }
                } else {
                    Text(inline(line))
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private var lines: [String] {
        let text = markdown.isEmpty ? "No release notes." : markdown
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
