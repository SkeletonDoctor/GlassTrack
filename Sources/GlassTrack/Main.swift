import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--cli") {
            runCLI(Array(args[(i + 1)...]))
        } else {
            GlassTrackApp.main()
        }
    }

    /// Headless mode: GlassTrack --cli <video|folder> <outputDir> [preview|balanced|high|ultra] [step]
    static func runCLI(_ a: [String]) {
        guard a.count >= 2 else {
            print("usage: GlassTrack --cli <video|folder> <outputDir> [quality] [frameStep]")
            exit(2)
        }
        MainActor.assumeIsolated {
            var s = JobSettings()
            if a.count > 2, let q = QualityPreset(rawValue: a[2]) { s.quality = q }
            if a.count > 3, let n = Int(a[3]) { s.frameStep = n }
            s.undistort = false
            let job = TrackJob(input: URL(fileURLWithPath: a[0]), settings: s,
                               outputRoot: URL(fileURLWithPath: a[1]))
            var lastPct = -1
            job.onLog = { line in
                let pct = Int(job.overallProgress * 100)
                if pct != lastPct { lastPct = pct; print(String(format: "[%3d%%]", pct)) }
                print("  " + line)
            }
            Task { @MainActor in
                await job.loadInputPreview()
                job.start()
                while job.status == .running || job.status == .idle {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                for st in job.stages { print("\(st.id.title): \(st.state) — \(st.detail)") }
                if let s = job.stats {
                    print("Registered \(s.registeredImages)/\(s.totalImages), points \(s.points), reproj \(s.meanReprojectionError ?? -1)")
                }
                print("Project: \(job.projectDir.path)")
                exit(job.status == .finished ? 0 : 1)
            }
        }
        RunLoop.main.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            // SwiftUI's onOpenURL usually handles this; it can also call us with an empty list.
            if let url = urls.first { JobStore.shared.pendingOpen = url }
        }
    }
}

struct GlassTrackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = JobStore.shared
    @State private var toolchain = Toolchain()

    var body: some Scene {
        WindowGroup("GlassTrack") {
            ContentView()
                .environment(store)
                .environment(toolchain)
                .frame(minWidth: 1040, minHeight: 680)
                .onOpenURL { store.pendingOpen = $0 }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Track…") { store.selection = nil }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(toolchain)
        }
    }
}

/// Holds all jobs and runs them one at a time.
@MainActor
@Observable
final class JobStore {
    static let shared = JobStore()

    var jobs: [TrackJob] = []
    var selection: TrackJob.ID?
    @ObservationIgnored private var terminating = false

    init() {
        load()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { JobStore.shared.prepareForQuit() }
        }
    }
    /// Footage opened via Finder / Dock, picked up by the New Track screen.
    var pendingOpen: URL? {
        didSet { if pendingOpen != nil { selection = nil } }
    }

    var outputRoot: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: "outputRoot") { return URL(fileURLWithPath: p) }
            return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GlassTrack", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: "outputRoot"); objectWillChangeToken += 1 }
    }
    private var objectWillChangeToken = 0

    var defaultSettings: JobSettings {
        get {
            _ = objectWillChangeToken
            guard let d = UserDefaults.standard.data(forKey: "defaultSettings"),
                  let s = try? JSONDecoder().decode(JobSettings.self, from: d) else { return JobSettings() }
            return s
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "defaultSettings")
            objectWillChangeToken += 1
        }
    }

    var selectedJob: TrackJob? { jobs.first { $0.id == selection } }

    func enqueue(_ job: TrackJob) {
        job.onPersist = { [weak self] in self?.save() }
        jobs.insert(job, at: 0)
        selection = job.id
        defaultSettings = job.settings
        save()
        pump()
    }

    func remove(_ job: TrackJob) {
        job.cancel()
        jobs.removeAll { $0.id == job.id }
        if selection == job.id { selection = nil }
        save()
    }

    /// Re-queues a track. Failed or cancelled tracks pick up from their last finished stage;
    /// `fromScratch` solves everything again.
    func retry(_ job: TrackJob, fromScratch: Bool = false) {
        if fromScratch {
            job.resetProgress()
        } else {
            job.status = .idle
        }
        save()
        pump()
    }

    // MARK: Persistence

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassTrack", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tracks.json")
    }

    private struct Saved: Codable {
        var jobs: [JobSnapshot]
        var selection: UUID?
    }

    func save() {
        guard !terminating else { return }
        write()
    }

    private func write() {
        let saved = Saved(jobs: jobs.map(\.snapshot), selection: selection)
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(saved).write(to: Self.storeURL, options: .atomic)
        } catch {
            NSLog("GlassTrack: could not save tracks: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let saved = try? dec.decode(Saved.self, from: data) else { return }
        jobs = saved.jobs.map { snap in
            let job = TrackJob(snapshot: snap)
            job.onPersist = { [weak self] in self?.save() }
            Task { await job.loadThumbnail() }
            return job
        }
        selection = saved.selection.flatMap { id in jobs.contains { $0.id == id } ? id : nil }
        // Pick up queued or interrupted solves once the run loop is going.
        Task { @MainActor in
            if ToolLocator.colmap() != nil { self.pump() }
        }
    }

    /// Saves state with running solves still marked running (so they resume next launch),
    /// then stops their child processes.
    private func prepareForQuit() {
        write()
        terminating = true
        for job in jobs where job.status == .running { job.cancel() }
    }

    /// Starts the oldest waiting job when nothing is running.
    func pump() {
        guard !jobs.contains(where: { $0.status == .running }) else { return }
        guard let next = jobs.last(where: { $0.status == .idle }) else { return }
        next.start()
        Task { @MainActor in
            while next.status == .running || next.status == .idle {
                try? await Task.sleep(for: .milliseconds(500))
            }
            notifyFinished(next)
            pump()
        }
    }

    private func notifyFinished(_ job: TrackJob) {
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        NSSound(named: job.status == .finished ? "Glass" : "Basso")?.play()
    }
}

