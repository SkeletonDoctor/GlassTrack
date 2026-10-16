import Foundation

struct ProcessError: LocalizedError {
    let tool: String
    let code: Int32
    let tail: String

    var errorDescription: String? {
        "\(tool) exited with code \(code).\n\(tail)"
    }
}

/// Runs a command line tool, streaming merged stdout/stderr line by line.
/// The process is terminated when the calling task is cancelled.
enum ProcessRunner {
    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: URL? = nil,
        extraEnvironment: [String: String] = [:],
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ToolLocator.childPATH
        env["GLOG_logtostderr"] = "1"
        env["GLOG_alsologtostderr"] = "1"
        env.merge(extraEnvironment) { _, new in new }
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collector = LineCollector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(data)
            }
        }

        let name = URL(fileURLWithPath: executable).lastPathComponent
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in
                    cont.resume(returning: p.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            // COLMAP treats SIGTERM as a request for a graceful shutdown and can keep working
            // for a long time (e.g. finishing feature extraction), so force-kill shortly after.
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.75) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        // Drain anything left in the pipe.
        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? pipe.fileHandleForReading.readToEnd() { collector.append(rest) }
        collector.flush()

        try Task.checkCancellation()
        if status != 0 {
            throw ProcessError(tool: name, code: status, tail: collector.tail)
        }
        return collector.tail
    }
}

/// Splits a byte stream into lines (handles both \n and \r, which ffmpeg uses).
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var recent: [String] = []
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                lines.append(line)
            }
        }
        remember(lines)
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let line = String(data: buffer, encoding: .utf8) ?? ""
        buffer.removeAll()
        if !line.isEmpty { remember([line]) }
        lock.unlock()
        if !line.isEmpty { onLine(line) }
    }

    var tail: String {
        lock.lock(); defer { lock.unlock() }
        return recent.suffix(12).joined(separator: "\n")
    }

    private func remember(_ lines: [String]) {
        recent.append(contentsOf: lines)
        if recent.count > 200 { recent.removeFirst(recent.count - 200) }
    }
}
