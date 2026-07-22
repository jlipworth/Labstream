import Foundation
import PMSKit

/// Small, bounded, file-backed companion to `AppDiagnostics`' in-memory ring buffer.
///
/// The in-memory buffer is ideal for the user-exported report, but headset/off-head bugs can suspend
/// or terminate the process before a user exports anything. This sink writes the same already-redacted
/// `DiagnosticEvent` JSON lines into Application Support so `scripts/headset-evidence.sh` can copy
/// them after a repro. Rotation is intentionally tiny and local: diagnostics are a permanent feature,
/// so the file must never grow without bound.
final class DiagnosticFileLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL
    private let maxBytes: UInt64
    private let archiveCount: Int

    init(fileManager: FileManager = .default,
         maxBytes: UInt64 = 1_000_000,
         archiveCount: Int = 3) {
        self.fileManager = fileManager
        self.maxBytes = max(64_000, maxBytes)
        self.archiveCount = max(0, archiveCount)
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        self.directoryURL = support
            .appendingPathComponent("Labstream", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        self.fileURL = directoryURL.appendingPathComponent("app-diagnostics.jsonl")
    }

    var diagnosticsDirectory: URL { directoryURL }

    func append(_ event: DiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            rotateIfNeeded()
            let line = event.jsonLine() + "\n"
            guard let data = line.data(using: .utf8) else { return }
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Diagnostics must never perturb the app. Keep failure silent; the in-memory report and
            // unified log still receive the event.
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: fileURL)
        for index in 1...max(archiveCount, 1) {
            try? fileManager.removeItem(at: archiveURL(index))
        }
    }

    private func rotateIfNeeded() {
        guard fileSize(fileURL) >= maxBytes else { return }
        guard archiveCount > 0 else {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        try? fileManager.removeItem(at: archiveURL(archiveCount))
        if archiveCount >= 2 {
            for index in stride(from: archiveCount - 1, through: 1, by: -1) {
                let source = archiveURL(index)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try? fileManager.moveItem(at: source, to: archiveURL(index + 1))
            }
        }
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.moveItem(at: fileURL, to: archiveURL(1))
        }
    }

    private func archiveURL(_ index: Int) -> URL {
        directoryURL.appendingPathComponent("app-diagnostics.jsonl.\(index)")
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let raw = try? fileManager.attributesOfItem(atPath: url.path)[.size] else { return 0 }
        if let number = raw as? NSNumber { return number.uint64Value }
        if let int = raw as? Int { return UInt64(max(0, int)) }
        if let uint64 = raw as? UInt64 { return uint64 }
        return 0
    }
}
