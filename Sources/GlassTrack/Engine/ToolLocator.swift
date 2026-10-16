import Foundation

/// Finds the command line tools. GUI apps don't inherit the shell PATH, so we probe common locations.
enum ToolLocator {
    static let colmapKey = "toolPath.colmap"
    static let ffmpegKey = "toolPath.ffmpeg"
    static let ffprobeKey = "toolPath.ffprobe"
    static let blenderKey = "toolPath.blender"

    private static let searchDirs = [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin",
        NSHomeDirectory() + "/.local/bin",
    ]

    static func colmap() -> String? {
        resolve(key: colmapKey, name: "colmap", extra: [
            "/Applications/COLMAP.app/Contents/MacOS/colmap",
            "/Applications/COLMAP.app/Contents/MacOS/COLMAP",
        ])
    }

    static func ffmpeg() -> String? { resolve(key: ffmpegKey, name: "ffmpeg") }
    static func ffprobe() -> String? { resolve(key: ffprobeKey, name: "ffprobe") }

    static func blender() -> String? {
        resolve(key: blenderKey, name: "blender", extra: [
            "/Applications/Blender.app/Contents/MacOS/Blender",
            NSHomeDirectory() + "/Applications/Blender.app/Contents/MacOS/Blender",
        ])
    }

    private static func resolve(key: String, name: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: key), !custom.isEmpty,
           fm.isExecutableFile(atPath: custom) {
            return custom
        }
        for path in extra where fm.isExecutableFile(atPath: path) { return path }
        for dir in searchDirs {
            let p = dir + "/" + name
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// PATH handed to child processes so tools can find their own helpers.
    static var childPATH: String {
        (searchDirs + [ProcessInfo.processInfo.environment["PATH"] ?? ""]).joined(separator: ":")
    }
}
