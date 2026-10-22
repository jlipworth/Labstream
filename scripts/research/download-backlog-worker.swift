// Synthetic ownership experiment; deliberately does not import or mutate app state.
// Mirrors chapter TaskGroup result retention and the static 4 MiB FileHandle loop.
import Foundation
import Darwin

final class Counters: @unchecked Sendable {
    let lock = NSLock()
    var payloadBytes = 0, peakPayloadBytes = 0, payloads = 0, peakPayloads = 0
    var tasks = 0, peakTasks = 0
    var queued = 0, peakQueued = 0
    func queue(_ delta: Int) { lock.lock(); defer { lock.unlock() }
        queued += delta; peakQueued = max(peakQueued, queued)
    }
    func task(_ delta: Int) { lock.lock(); defer { lock.unlock() }
        tasks += delta; peakTasks = max(peakTasks, tasks)
    }
    func payload(_ delta: Int) { lock.lock(); defer { lock.unlock() }
        payloadBytes += delta; payloads += delta > 0 ? 1 : -1
        peakPayloadBytes = max(peakPayloadBytes, payloadBytes)
        peakPayloads = max(peakPayloads, payloads)
    }
}
final class Payload: @unchecked Sendable {
    let data: Data
    let counters: Counters
    init(bytes: Int, value: UInt8, counters: Counters) {
        self.data = Data(repeating: value, count: bytes)
        self.counters = counters
        counters.payload(bytes)
    }
    deinit { counters.payload(-data.count) }
}
actor Pacer {
    var next: UInt64 = 0
    func enter() async throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let deadline = max(now, next)
        next = deadline + 1_000_000 // 1,000x accelerated 1 request/s, one origin
        if deadline > now { try await Task.sleep(nanoseconds: deadline - now) }
    }
}
func peakRSS() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss) // Darwin reports bytes; RSS is not phys_footprint.
}
func size(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).intValue
}
func allocated(_ url: URL) throws -> Int64 {
    var info = stat()
    guard stat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
    return Int64(info.st_blocks) * 512 // allocated blocks, not bytes physically written
}
func append(_ source: URL, _ destination: URL, delay: UInt32, chunkPool: Bool) throws -> Int {
    let reader = try FileHandle(forReadingFrom: source)
    defer { try? reader.close() }
    let writer = try FileHandle(forWritingTo: destination)
    defer { try? writer.close() }
    try writer.seekToEnd()
    var total = 0
    if chunkPool {
        while true {
            let count: Int = try autoreleasepool {
                let data = try reader.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
                if data.isEmpty { return 0 }
                if delay > 0 { usleep(delay) }
                try writer.write(contentsOf: data)
                return data.count
            }
            if count == 0 { break }
            total += count
        }
        return total
    }
    while true {
        let data = try reader.read(upToCount: 4 * 1_024 * 1_024) ?? Data()
        if data.isEmpty { break }
        if delay > 0 { usleep(delay) }
        try writer.write(contentsOf: data)
        total += data.count
    }
    return total
}
@main struct Experiment {
    static func main() async throws {
        let args = CommandLine.arguments
        guard (6...7).contains(args.count), let count = Int(args[2]), let bytes = Int(args[3]),
              let delay = Int(args[4]), let window = Int(args[5]),
              (1...128).contains(count), (1...1_048_576).contains(bytes),
              (0...20).contains(delay), (0...3).contains(window),
              ["assets", "files"].contains(args[1]),
              (args[1] != "files" || count <= 32),
              (args[1] != "assets" || window <= 2) else { fatalError("bounded arguments required") }
        let bodyMiB = args.count == 7 ? Int(args[6]) ?? 0 : 8
        guard [8, 128].contains(bodyMiB), (args[1] == "assets" || count * bodyMiB <= 256) else {
            fatalError("bounded body size required")
        }
        let fm = FileManager.default
        let parent = ProcessInfo.processInfo.environment["RESEARCH_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? fm.temporaryDirectory
        let root = parent.appendingPathComponent("download-research-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let baseline = peakRSS(), start = DispatchTime.now().uptimeNanoseconds
        let counters = Counters(), pacer = Pacer()
        var result: [String: Any] = ["mode": args[1], "count": count, "delay_ms": delay,
                                    "window": window, "baseline_maxrss_bytes": baseline]
        if args[1] == "assets" {
            func fetch(_ i: Int) async throws -> (Int, Payload) {
                try await pacer.enter()
                try Task.checkCancellation()
                return (i, Payload(bytes: bytes, value: UInt8(i % 251), counters: counters))
            }
            func prepare(_ value: (Int, Payload)) async throws {
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                let staging = root.appendingPathComponent("stage-\(value.0)")
                let destination = root.appendingPathComponent("asset-\(value.0)")
                try value.1.data.write(to: staging, options: .atomic)
                try fm.moveItem(at: staging, to: destination)
                guard try size(destination) == bytes else { fatalError("size mismatch") }
            }
            if window == 0 {
                try await withThrowingTaskGroup(of: (Int, Payload).self) { group in
                    for i in 0..<count {
                        counters.task(1)
                        group.addTask {
                            defer { counters.task(-1) }
                            let value = try await fetch(i)
                            counters.queue(1)
                            return value
                        }
                    }
                    for try await value in group {
                        counters.queue(-1)
                        try await prepare(value)
                    }
                }
            } else {
                try await withThrowingTaskGroup(of: (Int, Payload).self) { group in
                    var submitted = 0
                    func submit(_ i: Int) {
                        counters.task(1)
                        group.addTask {
                            defer { counters.task(-1) }
                            let value = try await fetch(i)
                            counters.queue(1)
                            return value
                        }
                    }
                    while submitted < min(window, count) { submit(submitted); submitted += 1 }
                    while true {
                        var value = try await group.next()
                        guard value != nil else { break }
                        counters.queue(-1)
                        try await prepare(value!)
                        value = nil // release the consumed payload before refilling
                        if submitted < count { submit(submitted); submitted += 1 }
                    }
                }
            }
            guard counters.payloadBytes == 0, counters.tasks == 0 else { fatalError("retained ownership") }
            result["payload_size_bytes"] = bytes
            result["peak_owned_payload_bytes"] = counters.peakPayloadBytes
            result["peak_owned_payloads"] = counters.peakPayloads
            result["peak_unfinished_child_tasks"] = counters.peakTasks
            result["peak_unconsumed_result_count"] = counters.peakQueued
            result["peak_unconsumed_result_bytes"] = counters.peakQueued * bytes
            result["logical_asset_write_bytes"] = count * bytes
        } else {
            // Bounded fixture bodies: at most 256 MiB pending and 512 MiB source+destination.
            let bodyBytes = bodyMiB * 1_024 * 1_024
            var bodies: [URL] = []
            let block = Data(repeating: 0x5a, count: bytes)
            for i in 0..<count {
                let body = root.appendingPathComponent("body-\(i)")
                fm.createFile(atPath: body.path, contents: nil)
                let writer = try FileHandle(forWritingTo: body)
                var remaining = bodyBytes
                while remaining > 0 {
                    let n = min(remaining, block.count)
                    try writer.write(contentsOf: block.prefix(n)); remaining -= n
                }
                try writer.close(); bodies.append(body)
            }
            result["maxrss_after_fixture_bytes"] = peakRSS()
            let destination = root.appendingPathComponent("partial")
            fm.createFile(atPath: destination.path, contents: nil)
            var appended = 0, checkpoints = 0
            let ioQueue = DispatchQueue(label: "research.serial-file-io")
            for body in bodies {
                if window == 3 {
                    let copied: Int = try await withCheckedThrowingContinuation { continuation in
                        ioQueue.async {
                            do {
                                continuation.resume(returning: try append(
                                    body, destination, delay: UInt32(delay * 1_000), chunkPool: false))
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                    appended += copied
                } else if window == 1 {
                    appended += try autoreleasepool {
                        try append(body, destination, delay: UInt32(delay * 1_000), chunkPool: false)
                    }
                } else {
                    appended += try append(body, destination, delay: UInt32(delay * 1_000), chunkPool: window == 2)
                }
                guard try size(destination) == appended else { fatalError("checkpoint mismatch") }
                checkpoints += 1 // ordinary checkpoint observes/persists length, no body recopy
                try fm.removeItem(at: body)
            }
            result["maxrss_after_append_bytes"] = peakRSS()
            let copy = root.appendingPathComponent("handoff-copy")
            try fm.copyItem(at: destination, to: copy) // isolated reconstruction/copy proxy
            result["maxrss_after_copy_bytes"] = peakRSS()
            guard try size(copy) == appended else { fatalError("copy mismatch") }
            result["body_size_bytes"] = bodyBytes
            result["autorelease_scope"] = ["none", "body", "chunk", "dispatch-body"][window]
            result["peak_pending_file_bytes"] = count * bodyBytes
            result["peak_pending_file_count"] = count
            result["logical_fixture_write_bytes"] = count * bodyBytes
            result["logical_append_write_bytes"] = appended
            result["ordinary_checkpoint_count"] = checkpoints
            result["handoff_copy_logical_bytes"] = appended
            result["final_allocated_blocks_bytes"] = try allocated(destination)
            result["copy_allocated_blocks_bytes"] = try allocated(copy)
            result["copy_read_chunk_bytes"] = 4 * 1_024 * 1_024
        }
        result["maxrss_bytes"] = peakRSS()
        result["elapsed_seconds"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
