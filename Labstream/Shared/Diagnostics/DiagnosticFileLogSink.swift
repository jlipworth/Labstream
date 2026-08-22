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
    private let queue: DispatchQueue
    private let fileManager: FileManager
    private let directoryURL: URL
    private let fileURL: URL
    private let maxBytes: UInt64
    private let archiveCount: Int
    private let flushInterval: TimeInterval
    private let flushByteThreshold: Int
    private var bufferedLines: [Data] = []
    private var bufferedBytes = 0
    private var flushGeneration: UInt64 = 0
    private var isFlushScheduled = false

    init(fileManager: FileManager = .default,
         maxBytes: UInt64 = 1_000_000,
         archiveCount: Int = 3,
         flushInterval: TimeInterval = 0.5,
         flushByteThreshold: Int = 32_768,
         directoryURL providedDirectoryURL: URL? = nil,
         queue: DispatchQueue? = nil) {
        self.fileManager = fileManager
        self.maxBytes = max(64_000, maxBytes)
        self.archiveCount = max(0, archiveCount)
        self.flushInterval = max(0, flushInterval)
        self.flushByteThreshold = max(1, flushByteThreshold)
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        self.directoryURL = providedDirectoryURL ?? support
            .appendingPathComponent("Labstream", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        self.fileURL = directoryURL.appendingPathComponent("app-diagnostics.jsonl")
        self.queue = queue ?? DispatchQueue(label: "org.labstream.Labstream.diagnostics.file")
    }

    var diagnosticsDirectory: URL { directoryURL }

    func append(_ event: DiagnosticEvent,
                durability: PersistenceDurabilityTier = .bestEffort) {
        precondition(durability == .bestEffort || durability == .ephemeral,
                     "Diagnostics cannot satisfy recovery or durable-barrier contracts")
        guard durability == .bestEffort,
              let data = (event.jsonLine() + "\n").data(using: .utf8) else { return }
        queue.async { [self] in
            bufferedLines.append(data)
            bufferedBytes += data.count
            if bufferedBytes >= flushByteThreshold {
                flushBufferedLines()
            } else {
                scheduleFlushIfNeeded()
            }
        }
    }

    /// Serial barrier used at real process inactivity. The normal crash-loss window is at most the
    /// configured interval or byte threshold; a lifecycle flush reduces that window to zero.
    func flush() {
        queue.sync { flushBufferedLines() }
    }

    private func flushBufferedLines() {
        guard !bufferedLines.isEmpty else {
            isFlushScheduled = false
            return
        }
        let lines = bufferedLines
        bufferedLines.removeAll(keepingCapacity: true)
        bufferedBytes = 0
        isFlushScheduled = false
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            for line in lines {
                // One pathological event must not defeat the file bound. Diagnostics are
                // best-effort, so discard an oversized JSONL record rather than corrupting it.
                guard UInt64(line.count) <= maxBytes else { continue }
                rotateIfNeeded(incomingBytes: UInt64(line.count))
                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            }
        } catch {
            // Diagnostics must never perturb the app. Keep failure silent; the in-memory report and
            // unified log still receive the event.
        }
    }

    func clear() {
        queue.sync {
            flushGeneration &+= 1
            bufferedLines.removeAll(keepingCapacity: false)
            bufferedBytes = 0
            isFlushScheduled = false
            try? fileManager.removeItem(at: fileURL)
            for index in 1...max(archiveCount, 1) {
                try? fileManager.removeItem(at: archiveURL(index))
            }
        }
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        let generation = flushGeneration
        queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            guard let self, self.flushGeneration == generation else { return }
            self.flushBufferedLines()
        }
    }

    private func rotateIfNeeded(incomingBytes: UInt64) {
        let existingBytes = fileSize(fileURL)
        guard existingBytes >= maxBytes
                || incomingBytes > maxBytes - min(existingBytes, maxBytes) else { return }
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
