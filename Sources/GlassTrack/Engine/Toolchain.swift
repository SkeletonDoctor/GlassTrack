import AppKit
import Foundation
import Observation

/// Detects and installs the external tools (Homebrew, COLMAP, FFmpeg, Blender).
@MainActor
@Observable
final class Toolchain {
    enum Tool: String, CaseIterable, Identifiable {
        case homebrew, colmap, ffmpeg, blender
        var id: String { rawValue }

        var title: String {
            switch self {
            case .homebrew: "Homebrew"
            case .colmap: "COLMAP"
            case .ffmpeg: "FFmpeg"
            case .blender: "Blender"
            }
        }

        var subtitle: String {
            switch self {
            case .homebrew: "Package manager used to install the tools"
            case .colmap: "Structure-from-Motion camera solver"
            case .ffmpeg: "Converts video into frames"
            case .blender: "Optional – builds a ready .blend scene"
            }
        }

        var symbol: String {
            switch self {
            case .homebrew: "mug"
            case .colmap: "camera.viewfinder"
            case .ffmpeg: "film"
            case .blender: "cube.transparent"
            }
        }

        var required: Bool { self != .blender }
    }

    private(set) var paths: [Tool: String] = [:]
    var installing = false
    var currentStep = ""
    var log: [String] = []
    var lastError: String?
    var setupDismissed = false

    var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var isReady: Bool {
        if ProcessInfo.processInfo.environment["GLASSTRACK_FORCE_SETUP"] != nil && !setupDismissed { return false }
        return paths[.colmap] != nil && paths[.ffmpeg] != nil && ToolLocator.ffprobe() != nil
    }

    init() { refresh() }

    func refresh() {
        paths[.homebrew] = brewPath
        paths[.colmap] = ToolLocator.colmap()
        paths[.ffmpeg] = (ToolLocator.ffmpeg() != nil && ToolLocator.ffprobe() != nil) ? ToolLocator.ffmpeg() : nil
        paths[.blender] = ToolLocator.blender()
    }

    func isInstalled(_ tool: Tool) -> Bool { paths[tool] != nil }

    /// Installs everything that's missing. Homebrew itself needs an admin password, so its
    /// official installer is opened in Terminal and we wait for it to finish.
    func installMissing(includeBlender: Bool) async {
        guard !installing else { return }
        installing = true
        lastError = nil
        log.removeAll()
        defer { installing = false; currentStep = ""; refresh() }

        if brewPath == nil {
            currentStep = "Installing Homebrew – follow the prompts in Terminal…"
            append("Homebrew not found. Opening the official installer in Terminal.")
            openHomebrewInstaller()
            // Wait up to 30 minutes for brew to appear.
            for _ in 0..<900 {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                if brewPath != nil { break }
            }
            guard brewPath != nil else {
                lastError = "Homebrew was not installed. Finish the installer in Terminal, then try again."
                return
            }
            append("Homebrew installed.")
        }
        guard let brew = brewPath else { return }

        var formulae: [String] = []
        if ToolLocator.colmap() == nil { formulae.append("colmap") }
        if ToolLocator.ffmpeg() == nil || ToolLocator.ffprobe() == nil { formulae.append("ffmpeg") }

        do {
            if !formulae.isEmpty {
                currentStep = "Installing \(formulae.joined(separator: " & "))… (this can take a few minutes)"
                try await brewRun(brew, ["install"] + formulae)
            }
            if includeBlender && ToolLocator.blender() == nil {
                currentStep = "Installing Blender…"
                try await brewRun(brew, ["install", "--cask", "blender"])
            }
            append("All done.")
        } catch {
            lastError = error.localizedDescription
            append("Error: \(error.localizedDescription)")
        }
    }

    private func brewRun(_ brew: String, _ args: [String]) async throws {
        append("$ brew \(args.joined(separator: " "))")
        var env = [
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "NONINTERACTIVE": "1",
        ]
        env["HOME"] = NSHomeDirectory()
        try await ProcessRunner.run(brew, args, extraEnvironment: env) { [weak self] line in
            DispatchQueue.main.async { self?.append(line) }
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    private func openHomebrewInstaller() {
        let script = """
        #!/bin/bash
        echo "GlassTrack: installing Homebrew (you'll be asked for your Mac password)."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        echo
        echo "Done. You can close this window and return to GlassTrack."
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("install-homebrew.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            lastError = "Could not open Terminal: \(error.localizedDescription)"
        }
    }
}
