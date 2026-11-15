import Foundation

/// Reads the JSON that `MXCallStackTree.jsonRepresentation()` returns and keeps the one stack
/// worth reporting, in a form a maintainer can symbolicate.
///
/// MetricKit frames carry no symbol names. Each has the binary's name and UUID, the runtime
/// `address`, and `offsetIntoBinaryTextSegment`. The runtime address is useless after the process
/// is gone (the load address is randomized), so a frame is stored as `Binary +0x<offset>`, which
/// `scripts/symbolicate-report.py` resolves against the build's dSYM.
public enum MetricKitCallStackParser {
    public struct Stack: Sendable, Equatable {
        /// `Binary +0x<offset into its text segment>`, in tree order from the root frame.
        public var frames: [String]
        /// UUID of the first frame's binary whose name matches `appBinaryName`, to confirm the
        /// dSYM matches. Hex and hyphens only.
        public var appBinaryUUID: String?
    }

    /// - Parameter appBinaryName: the app executable's name, used to pick `appBinaryUUID`.
    public static func stack(fromJSON data: Data, appBinaryName: String?) -> Stack {
        guard let tree = try? JSONDecoder().decode(Tree.self, from: data),
              let stacks = tree.callStacks, !stacks.isEmpty else {
            return Stack(frames: [], appBinaryUUID: nil)
        }
        // A crash tree has one stack per thread and marks the crashed one. A hang or CPU tree
        // is a single sampled tree, so the first stack is the only candidate.
        let chosen = stacks.first { $0.threadAttributed == true } ?? stacks[0]
        var frames: [String] = []
        var uuid: String?
        collect(chosen.callStackRootFrames, into: &frames, uuid: &uuid, appBinaryName: appBinaryName)
        return Stack(frames: frames, appBinaryUUID: uuid)
    }

    private static func collect(_ nodes: [Frame]?, into out: inout [String], uuid: inout String?,
                                appBinaryName: String?) {
        // Follow the heaviest branch only: a sampled tree can fan out, and one path is what a
        // report has room for.
        guard let node = (nodes ?? []).max(by: { ($0.sampleCount ?? 0) < ($1.sampleCount ?? 0) }) else { return }
        let name = node.binaryName.flatMap { $0.isEmpty ? nil : $0 } ?? "?"
        if let offset = node.offsetIntoBinaryTextSegment {
            out.append("\(name) +0x\(String(offset, radix: 16))")
        } else {
            out.append(name)
        }
        if uuid == nil, let appBinaryName, name == appBinaryName, let value = node.binaryUUID {
            let cleaned = value.filter { $0.isHexDigit || $0 == "-" }
            if !cleaned.isEmpty { uuid = String(cleaned.prefix(36)) }
        }
        collect(node.subFrames, into: &out, uuid: &uuid, appBinaryName: appBinaryName)
    }

    private struct Tree: Decodable {
        let callStacks: [CallStack]?
    }

    private struct CallStack: Decodable {
        let threadAttributed: Bool?
        let callStackRootFrames: [Frame]?
    }

    private struct Frame: Decodable {
        let binaryName: String?
        let binaryUUID: String?
        let offsetIntoBinaryTextSegment: UInt64?
        let sampleCount: Int?
        let subFrames: [Frame]?
    }
}
