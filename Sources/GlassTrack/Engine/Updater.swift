import AppKit
import CryptoKit
import Foundation
import Observation

/// Self-updater: looks for a newer release on GitHub, downloads its .zip, checks it and swaps
/// it in for the running app.
///
/// The app is ad-hoc signed, so there is no developer identity to check the download against.
/// Trust comes from HTTPS to github.com, the SHA-256 digest GitHub publishes for the asset,
/// and a check that the unpacked bundle is a validly sealed GlassTrack of the expected version.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    nonisolated static let repo = "SkeletonDoctor/GlassTrack"
    static let repoURL = URL(string: "https://github.com/\(repo)")!
    static let releasesURL = repoURL.appendingPathComponent("releases")
    static let issuesURL = repoURL.appendingPathComponent("issues/new")

    struct Release: Equatable {
        var version: String
        var title: String
        var notes: String
        var pageURL: URL
        var zipURL: URL?
        var sha256: String?
    }

    enum Phase: Equatable {
        case idle, checking, upToDate, available, downloading, installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var latest: Release?
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date
    /// Drives the update sheet.
    var showSheet = false

    var autoCheck: Bool = UserDefaults.standard.object(forKey: Keys.autoCheck) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Keys.autoCheck) }
    }

    private enum Keys {
        static let autoCheck = "autoCheckUpdates"
        static let lastChecked = "updateLastChecked"
        static let skipped = "updateSkippedVersion"
    }

    @ObservationIgnored private var timer: Task<Void, Never>?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A newer version the user hasn't chosen to skip (shown as the sidebar banner).
    var offered: Release? {
        guard let latest, Self.isNewer(latest.version, than: Self.currentVersion),
              latest.version != UserDefaults.standard.string(forKey: Keys.skipped) else { return nil }
        return latest
    }

    var isBusy: Bool { phase == .checking || phase == .downloading || phase == .installing }

    /// Why the app can't replace itself, or nil when it can.
    var installBlocker: String? {
        let app = Bundle.main.bundleURL
        if app.pathExtension != "app" { return "This is a development build." }
        if app.path.contains("/AppTranslocation/") {
            return "Move GlassTrack into your Applications folder first, then open it from there."
        }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "GlassTrack can't write to \(app.deletingLastPathComponent().path)."
        }
        return nil
    }

    // MARK: Checking

    /// Checks at launch and then once a day while the app stays open.
    func startAutomaticChecks() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                if let self, self.autoCheck, !self.isBusy { await self.check() }
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    /// `manual` checks open the sheet and also report "up to date" and errors.
    func check(manual: Bool = false) async {
        guard !isBusy else { if manual { showSheet = true }; return }
        if manual {
            UserDefaults.standard.removeObject(forKey: Keys.skipped)
            showSheet = true
        }
        let before = phase
        phase = .checking
        do {
            let release = try await Self.fetchLatest()
            latest = release
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
            phase = Self.isNewer(release.version, than: Self.currentVersion) ? .available : .upToDate
        } catch {
            // A background check that fails (offline, rate-limited) stays quiet.
            phase = manual ? .failed("Couldn't check for updates. \(error.localizedDescription)") : before
        }
    }

    func skipOffered() {
        if let latest { UserDefaults.standard.set(latest.version, forKey: Keys.skipped) }
        showSheet = false
    }

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
            var digest: String?
        }
        var tag_name: String
        var name: String?
        var body: String?
        var html_url: URL
        var assets: [Asset]
    }

    nonisolated static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GlassTrack-Updater", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError("GitHub answered with status \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let api = try JSONDecoder().decode(APIRelease.self, from: data)
        let version = api.tag_name.hasPrefix("v") ? String(api.tag_name.dropFirst()) : api.tag_name
        let zip = api.assets.first { $0.name.lowercased().hasSuffix(".zip") }
        var sha: String?
        if let d = zip?.digest, d.hasPrefix("sha256:") { sha = String(d.dropFirst(7)).lowercased() }
        return Release(version: version, title: api.name ?? "GlassTrack \(version)", notes: api.body ?? "",
                       pageURL: api.html_url, zipURL: zip?.browser_download_url, sha256: sha)
    }

    /// Numeric, component-wise comparison ("1.10" is newer than "1.9").
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Installing

    /// Downloads and installs the latest release, then relaunches the app.
    func installAndRelaunch() async {
        guard let release = latest, !isBusy else { return }
        do {
            try await install(release)
            relaunch()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Downloads, verifies and swaps in `release`. The running process keeps working from the
    /// old (moved) bundle until it quits.
    func install(_ release: Release) async throws {
        if let blocker = installBlocker { throw UpdateError(blocker) }
        guard let zipURL = release.zipURL, zipURL.scheme == "https", zipURL.host == "github.com" else {
            throw UpdateError("This release has no downloadable app. Get it from the release page.")
        }
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL

        phase = .downloading
        let (tmpZip, response) = try await URLSession.shared.download(from: zipURL)
        defer { try? fm.removeItem(at: tmpZip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("The download failed (status \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }

        phase = .installing
        if let expected = release.sha256 {
            let actual = try await Task.detached { try Self.sha256(of: tmpZip) }.value
            guard actual == expected else {
                throw UpdateError("The download doesn't match the checksum GitHub lists for it, so it wasn't installed.")
            }
        }

        // Unpack next to the app (same volume) so the swap is a pair of renames.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: appURL, create: true)
        defer { try? fm.removeItem(at: staging) }
        let unpacked = staging.appendingPathComponent("new", isDirectory: true)
        try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", tmpZip.path, unpacked.path]) { _ in }
        guard let newApp = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError("The download didn't contain an app.")
        }

        // It has to be this app, at the version we were told, with an intact code seal.
        let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError("The download isn't GlassTrack \(release.version), so it wasn't installed.")
        }
        do {
            try await ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) { _ in }
        } catch {
            throw UpdateError("The downloaded app is damaged, so it wasn't installed.")
        }
        _ = try? await ProcessRunner.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path]) { _ in }

        let old = staging.appendingPathComponent("old.app", isDirectory: true)
        try fm.moveItem(at: appURL, to: old)
        do {
            try fm.moveItem(at: newApp, to: appURL)
        } catch {
            try? fm.moveItem(at: old, to: appURL)
            throw error
        }
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit, then open the new copy.
        p.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                       String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        try? p.run()
        // AppKit refuses to quit while a sheet is up, so close the update sheet first.
        showSheet = false
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            NSApp.terminate(nil)
        }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
