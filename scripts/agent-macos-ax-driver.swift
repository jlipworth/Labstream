#!/usr/bin/env -S xcrun swift

import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO

private enum DriverError: String, Error {
    case invalidArguments = "invalid_arguments"
    case processUnavailable = "process_unavailable"
    case accessibilityNotTrusted = "accessibility_not_trusted"
    case targetNotFound = "target_not_found"
    case targetAmbiguous = "target_ambiguous"
    case actionFailed = "action_failed"
    case assertionFailed = "assertion_failed"
    case outputFailed = "output_failed"
}

private struct Arguments {
    let pid: pid_t
    let output: URL
    let screenshotBefore: URL
    let screenshotAfter: URL
    let timeout: TimeInterval
    let captureOnly: Bool
}

private struct DriverResult: Codable {
    let schemaVersion: Int
    let status: String
    let pid: pid_t
    let scenario: String
    let completedStage: String
    let actionCount: Int
    let windowID: UInt32?
    let errorCode: String?
}

private func parseArguments() throws -> Arguments {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 10 || arguments.count == 11 else { throw DriverError.invalidArguments }
    var values: [String: String] = [:]
    var captureOnly = false
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        if flag == "--capture-only", !captureOnly {
            captureOnly = true
            index += 1
            continue
        }
        guard ["--pid", "--output", "--screenshot-before", "--screenshot-after", "--timeout"]
                .contains(flag),
              values[flag] == nil, index + 1 < arguments.count else {
            throw DriverError.invalidArguments
        }
        values[flag] = arguments[index + 1]
        index += 2
    }
    guard let rawPID = values["--pid"], let pid = pid_t(rawPID), pid > 1,
          let rawOutput = values["--output"], !rawOutput.isEmpty,
          let rawBefore = values["--screenshot-before"], !rawBefore.isEmpty,
          let rawAfter = values["--screenshot-after"], !rawAfter.isEmpty,
          let rawTimeout = values["--timeout"], let timeout = TimeInterval(rawTimeout),
          (1...60).contains(timeout) else { throw DriverError.invalidArguments }
    return Arguments(pid: pid, output: URL(fileURLWithPath: rawOutput),
                     screenshotBefore: URL(fileURLWithPath: rawBefore),
                     screenshotAfter: URL(fileURLWithPath: rawAfter), timeout: timeout,
                     captureOnly: captureOnly)
}

private func write(_ result: DriverResult, to output: URL) throws {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(result)
        data.append(0x0a)
        try data.write(to: output, options: .atomic)
    } catch {
        throw DriverError.outputFailed
    }
}

private final class FixtureDriver {
    private let pid: pid_t
    private let root: AXUIElement
    private let timeout: TimeInterval
    private(set) var completedStage = "attached"
    private(set) var actionCount = 0

    init(pid: pid_t, timeout: TimeInterval) throws {
        guard kill(pid, 0) == 0,
              let application = NSRunningApplication(processIdentifier: pid) else {
            throw DriverError.processUnavailable
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary) else {
            throw DriverError.accessibilityNotTrusted
        }
        let root = AXUIElementCreateApplication(pid)
        if !application.isActive {
            _ = application.activate(options: [.activateAllWindows])
            // After simulator automation, AppKit activation can remain advisory. The runner already
            // requires Accessibility trust, so request the exact target process as frontmost via AX
            // and wait briefly. Store captures must not silently publish a dimmed inactive window.
            _ = AXUIElementSetAttributeValue(root, kAXFrontmostAttribute as CFString,
                                             kCFBooleanTrue)
            var rawWindows: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString,
                                             &rawWindows) == .success,
               let window = (rawWindows as? [AXUIElement])?.first {
                _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString,
                                                 kCFBooleanTrue)
                _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString,
                                                 kCFBooleanTrue)
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            let activationDeadline = Date().addingTimeInterval(min(timeout, 2))
            while !application.isActive && Date() < activationDeadline {
                usleep(50_000)
            }
        }
        // Some headless host sessions prohibit foreground changes even with AX trust. The runner's
        // window-only capture remains privacy-safe in that state; final editorial review decides
        // whether the inactive appearance is acceptable or a person should focus and recapture.
        self.pid = pid
        self.root = root
        self.timeout = timeout
    }

    func run(screenshotBefore: URL, screenshotAfter: URL, captureOnly: Bool) throws {
        try captureWindow(to: screenshotBefore)
        if captureOnly {
            try captureWindow(to: screenshotAfter)
            completedStage = "home_captured"
            return
        }
        let target = try waitForUniquePressable(identifier: "labstream.home.fixture-resume.plex-orbit")
        completedStage = "fixture_item_found"
        guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
            throw DriverError.actionFailed
        }
        actionCount = 1
        completedStage = "fixture_item_opened"
        guard try waitForText("Some signals should stay distant.") else {
            throw DriverError.assertionFailed
        }
        completedStage = "detail_asserted"
        try captureWindow(to: screenshotAfter)
    }

    private func captureWindow(to output: URL) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var windowID: UInt32?
        repeat {
            windowID = largestWindowID(for: pid)
            if windowID == nil { usleep(50_000) }
        } while windowID == nil && Date() < deadline && kill(pid, 0) == 0
        guard let windowID else { throw DriverError.actionFailed }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l\(windowID)", output.path]
        try? process.run()
        process.waitUntilExit()
        let fileSize = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard process.terminationStatus == 0, (fileSize ?? 0) > 0 else {
            throw DriverError.actionFailed
        }
    }

    private func waitForUniquePressable(identifier: String) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let matches = try elements { element in
                self.stringAttribute("AXIdentifier", element: element) == identifier
                    && self.supportsPress(element)
            }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw DriverError.targetAmbiguous }
            usleep(50_000)
        } while Date() < deadline && kill(pid, 0) == 0
        throw DriverError.targetNotFound
    }

    private func waitForText(_ expected: String) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let matches = try elements { element in
                ["AXValue", "AXTitle", "AXDescription"].contains { attribute in
                    self.stringAttribute(attribute, element: element) == expected
                }
            }
            if matches.count == 1 { return true }
            if matches.count > 1 { throw DriverError.targetAmbiguous }
            usleep(50_000)
        } while Date() < deadline && kill(pid, 0) == 0
        return false
    }

    private func elements(matching predicate: (AXUIElement) -> Bool) throws -> [AXUIElement] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var offset = 0
        var visited = Set<CFHashCode>()
        var result: [AXUIElement] = []
        while offset < queue.count {
            guard queue.count <= 10_000 else { throw DriverError.targetNotFound }
            let (element, depth) = queue[offset]
            offset += 1
            guard visited.insert(CFHash(element)).inserted else { continue }
            if predicate(element) { result.append(element) }
            guard depth < 40 else { continue }
            var rawChildren: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                                      &rawChildren)
            if error == .success, let children = rawChildren as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            } else if ![.attributeUnsupported, .noValue, .cannotComplete, .invalidUIElement]
                        .contains(error) {
                throw DriverError.targetNotFound
            }
        }
        return result
    }

    private func stringAttribute(_ attribute: String, element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func supportsPress(_ element: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              let names = actions as? [String] else { return false }
        return names.contains(kAXPressAction as String)
    }
}

private func largestWindowID(for pid: pid_t) -> UInt32? {
    guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] else { return nil }
    return raw.compactMap { entry -> (UInt32, CGFloat)? in
        guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let width = (bounds["Width"] as? NSNumber)?.doubleValue,
              let height = (bounds["Height"] as? NSNumber)?.doubleValue else { return nil }
        return (number, width * height)
    }.max(by: { $0.1 < $1.1 })?.0
}

// MARK: - Live-catalog primitives (`live <operation>`)
//
// `scripts/app-store-screenshots.py live … --target macos` composes these one-shot operations
// against the exact PID it launched without arguments. Each prints one JSON object on stdout.
// Exit codes match the fixture path: 0 passed, 1 failed, 2 blocked (a host precondition only a
// person can clear). Private values arrive through named environment variables and are never
// echoed. Nothing here posts mouse or keyboard events or moves the pointer, and no operation falls
// back to coordinates or to full-desktop capture.

private struct LiveFailure: Error {
    let code: String
    let blocked: Bool
    var detail: [String: Any] = [:]
}

private struct LiveQuery {
    var roles: [String] = []
    var identifier: String?
    var label: String?
    var labelPrefix: String?
    var isEmpty: Bool {
        roles.isEmpty && identifier == nil && label == nil && labelPrefix == nil
    }
}

private final class LiveDriver {
    private let pid: pid_t
    private let application: NSRunningApplication
    private let root: AXUIElement
    private let timeout: TimeInterval

    init(pid: pid_t, timeout: TimeInterval) throws {
        guard kill(pid, 0) == 0, let application = NSRunningApplication(processIdentifier: pid) else {
            throw LiveFailure(code: DriverError.processUnavailable.rawValue, blocked: false)
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary) else {
            throw LiveFailure(code: DriverError.accessibilityNotTrusted.rawValue, blocked: true)
        }
        self.pid = pid
        self.application = application
        self.root = AXUIElementCreateApplication(pid)
        self.timeout = timeout
    }

    // MARK: Attributes

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func string(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    private func element(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let raw = attribute(name, of: element), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(kAXPositionAttribute as String, of: element),
              let rawSize = attribute(kAXSizeAttribute as String, of: element),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(rawPosition, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(rawSize, to: AXValue.self), .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private func mainWindow() -> AXUIElement? {
        if let main = element(kAXMainWindowAttribute as String, of: root) { return main }
        return (attribute(kAXWindowsAttribute as String, of: root) as? [AXUIElement])?.first
    }

    // MARK: Queries

    private func walk(_ visit: (AXUIElement, Int) -> Void) {
        // Windows only (sheets included): the menu bar names the host account and repeats labels.
        let windows = attribute(kAXWindowsAttribute as String, of: root) as? [AXUIElement] ?? []
        var queue: [(AXUIElement, Int)] = windows.map { ($0, 0) }
        var offset = 0
        var visited = Set<CFHashCode>()
        while offset < queue.count, queue.count <= 20_000 {
            let (element, depth) = queue[offset]
            offset += 1
            guard visited.insert(CFHash(element)).inserted else { continue }
            visit(element, depth)
            guard depth < 40,
                  let children = attribute(kAXChildrenAttribute as String, of: element)
                    as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
    }

    private func matches(_ query: LiveQuery) -> [AXUIElement] {
        var result: [AXUIElement] = []
        walk { element, _ in
            if !query.roles.isEmpty,
               !query.roles.contains(self.string(kAXRoleAttribute as String, of: element) ?? "") {
                return
            }
            if let identifier = query.identifier,
               self.string("AXIdentifier", of: element) != identifier { return }
            if let label = query.label,
               ![kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                 kAXPlaceholderValueAttribute].contains(where: {
                   self.string($0 as String, of: element) == label
               }) { return }
            if let prefix = query.labelPrefix,
               ![kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains(where: {
                   self.string($0 as String, of: element)?.hasPrefix(prefix) == true
               }) { return }
            result.append(element)
        }
        return result
    }

    /// Waits for exactly one match. `first` accepts the first of several (document order).
    private func required(_ query: LiveQuery, first: Bool = false,
                          where predicate: (AXUIElement) -> Bool = { _ in true }) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        var count = 0
        repeat {
            let found = matches(query).filter(predicate)
            count = found.count
            if count == 1 || (first && count > 1) { return found[0] }
            usleep(100_000)
        } while Date() < deadline && kill(pid, 0) == 0
        throw LiveFailure(code: count > 1 ? DriverError.targetAmbiguous.rawValue
                                           : DriverError.targetNotFound.rawValue,
                          blocked: false, detail: ["matches": count])
    }

    // MARK: Window

    private func screenScale(for frame: CGRect) -> Double? {
        // Accessibility uses a top-left origin on the primary display; AppKit a bottom-left one.
        guard let primary = NSScreen.screens.first else { return nil }
        let center = CGPoint(x: frame.midX, y: primary.frame.height - frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? primary
        return Double(screen.backingScaleFactor)
    }

    private func isFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    func windowInfo() throws -> [String: Any] {
        // A just-launched app has no window for a moment.
        let deadline = Date().addingTimeInterval(timeout)
        while mainWindow().flatMap({ frame(of: $0) }) == nil, largestWindowID(for: pid) == nil,
              Date() < deadline, kill(pid, 0) == 0 {
            usleep(100_000)
        }
        guard let window = mainWindow(), let frame = frame(of: window),
              largestWindowID(for: pid) != nil else {
            throw LiveFailure(code: "window_unavailable", blocked: false)
        }
        var info: [String: Any] = [
            "x": Double(frame.origin.x), "y": Double(frame.origin.y),
            "width": Double(frame.width), "height": Double(frame.height),
            "frontmost": isFrontmost(),
        ]
        if let scale = screenScale(for: frame) { info["scale"] = scale }
        if let windowID = largestWindowID(for: pid) { info["windowID"] = Int(windowID) }
        return info
    }

    func preflight() throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw LiveFailure(code: "screen_recording_not_permitted", blocked: true)
        }
        return try windowInfo()
    }

    /// Requests frontmost status for the exact PID and reports whether the system granted it.
    func activate() throws -> [String: Any] {
        if !isFrontmost() {
            _ = application.activate(options: [.activateAllWindows])
            _ = AXUIElementSetAttributeValue(root, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if let window = mainWindow() {
                _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
            let deadline = Date().addingTimeInterval(min(timeout, 3))
            while !isFrontmost() && Date() < deadline { usleep(50_000) }
        }
        return ["frontmost": isFrontmost()]
    }

    func resize(width: Double, height: Double) throws -> [String: Any] {
        guard let window = mainWindow(), let current = frame(of: window) else {
            throw LiveFailure(code: "window_unavailable", blocked: false)
        }
        // Keep the window on its current display, inside the area clear of the menu bar and Dock.
        var origin = current.origin
        if let primary = NSScreen.screens.first {
            let center = CGPoint(x: current.midX, y: primary.frame.height - current.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? primary
            let visible = screen.visibleFrame
            origin = CGPoint(x: visible.minX + max(0, (visible.width - width) / 2),
                             y: primary.frame.height - visible.maxY)
        }
        var size = CGSize(width: width, height: height)
        func apply() {
            if let value = AXValueCreate(.cgPoint, &origin) {
                _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
            if let value = AXValueCreate(.cgSize, &size) {
                _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
            }
        }
        apply()
        // A tiling window manager re-tiles a moment after the request, so the size must still
        // hold after a settle period, not merely right after it was set.
        var actual = current
        var stableSince: Date?
        let deadline = Date().addingTimeInterval(min(timeout, 6))
        repeat {
            usleep(150_000)
            actual = frame(of: window) ?? actual
            if abs(actual.width - width) < 0.5 && abs(actual.height - height) < 0.5 {
                let since = stableSince ?? Date()
                stableSince = since
                if Date().timeIntervalSince(since) >= 1.0 { break }
            } else {
                stableSince = nil
            }
        } while Date() < deadline
        let detail: [String: Any] = ["width": Double(actual.width), "height": Double(actual.height),
                                     "requestedWidth": width, "requestedHeight": height]
        guard let stableSince, Date().timeIntervalSince(stableSince) >= 1.0 else {
            throw LiveFailure(code: "window_size_mismatch", blocked: false, detail: detail)
        }
        return try windowInfo()
    }

    // MARK: Element operations

    func count(_ query: LiveQuery) -> [String: Any] { ["matches": matches(query).count] }

    func wait(_ query: LiveQuery) throws -> [String: Any] {
        _ = try required(query, first: true)
        return [:]
    }

    func press(_ query: LiveQuery, first: Bool) throws -> [String: Any] {
        let target = try required(query, first: first) {
            self.actions(of: $0).contains(kAXPressAction as String)
        }
        guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
            throw LiveFailure(code: DriverError.actionFailed.rawValue, blocked: false)
        }
        return [:]
    }

    /// Selects the source-list row that contains the matched element (native List selection).
    func selectRow(_ query: LiveQuery) throws -> [String: Any] {
        var candidate = try required(query)
        for _ in 0..<6 {
            if string(kAXRoleAttribute as String, of: candidate) == kAXRowRole as String {
                guard AXUIElementSetAttributeValue(candidate, kAXSelectedAttribute as CFString,
                                                   kCFBooleanTrue) == .success else {
                    throw LiveFailure(code: DriverError.actionFailed.rawValue, blocked: false)
                }
                return [:]
            }
            guard let parent = element(kAXParentAttribute as String, of: candidate) else { break }
            candidate = parent
        }
        throw LiveFailure(code: DriverError.targetNotFound.rawValue, blocked: false)
    }

    /// Performs a named accessibility action (SwiftUI `accessibilityAction(named:)`).
    func perform(_ name: String, on query: LiveQuery) throws -> [String: Any] {
        let target = try required(query)
        // AppKit reports custom actions as "Name:<name>\nTarget:…\nSelector:…".
        guard let action = actions(of: target).first(where: {
            $0 == name || $0.hasPrefix("Name:\(name)\n")
        }), AXUIElementPerformAction(target, action as CFString) == .success else {
            throw LiveFailure(code: DriverError.actionFailed.rawValue, blocked: false)
        }
        return [:]
    }

    /// Gives the matched element keyboard focus.
    func focus(_ query: LiveQuery) throws -> [String: Any] {
        let target = try required(query)
        guard AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString,
                                           kCFBooleanTrue) == .success else {
            throw LiveFailure(code: DriverError.actionFailed.rawValue, blocked: false)
        }
        return [:]
    }

    /// Sets a text field from the named environment variable. The value is never written out.
    func setValue(_ query: LiveQuery, environmentName: String) throws -> [String: Any] {
        guard let value = ProcessInfo.processInfo.environment[environmentName], !value.isEmpty else {
            throw LiveFailure(code: "value_unavailable", blocked: true)
        }
        let target = try required(query)
        _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementSetAttributeValue(target, kAXValueAttribute as CFString,
                                           value as CFString) == .success else {
            throw LiveFailure(code: DriverError.actionFailed.rawValue, blocked: false)
        }
        return [:]
    }

    /// Captures only this process's window, without its shadow. A window capture is transparent
    /// outside the rounded corners; `matte` (RRGGBB) flattens it onto that colour so a later
    /// JPEG conversion cannot turn the corners white.
    func capture(to output: URL, matte: String?) throws -> [String: Any] {
        guard let windowID = largestWindowID(for: pid) else {
            throw LiveFailure(code: "window_unavailable", blocked: false)
        }
        try? FileManager.default.removeItem(at: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(windowID)", output.path]
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let fileSize = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard process.terminationStatus == 0, fileSize > 0 else {
            // screencapture cannot read another process's window without Screen Recording access.
            throw LiveFailure(code: CGPreflightScreenCaptureAccess()
                                ? DriverError.actionFailed.rawValue
                                : "screen_recording_not_permitted",
                              blocked: !CGPreflightScreenCaptureAccess())
        }
        if let matte {
            guard let rgb = UInt32(matte, radix: 16), matte.count == 6,
                  let source = CGImageSourceCreateWithURL(output as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(
                    data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let destination = CGImageDestinationCreateWithURL(
                    output as CFURL, "public.png" as CFString, 1, nil) else {
                throw LiveFailure(code: DriverError.outputFailed.rawValue, blocked: false)
            }
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(red: CGFloat((rgb >> 16) & 0xff) / 255,
                                 green: CGFloat((rgb >> 8) & 0xff) / 255,
                                 blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
            context.fill(bounds)
            context.draw(image, in: bounds)
            guard let flattened = context.makeImage() else {
                throw LiveFailure(code: DriverError.outputFailed.rawValue, blocked: false)
            }
            CGImageDestinationAddImage(destination, flattened, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw LiveFailure(code: DriverError.outputFailed.rawValue, blocked: false)
            }
        }
        return ["windowID": Int(windowID)]
    }

    /// Structure only: roles, identifiers and labels of named elements. Text-field values are
    /// never read, so a filled sign-in form does not leak through a dump.
    func dump() -> [String: Any] {
        var lines: [String] = []
        walk { element, depth in
            let role = self.string(kAXRoleAttribute as String, of: element) ?? "?"
            var parts: [String] = []
            for name in ["AXIdentifier", kAXTitleAttribute as String,
                         kAXDescriptionAttribute as String,
                         kAXPlaceholderValueAttribute as String] {
                if let value = self.string(name, of: element), !value.isEmpty {
                    parts.append("\(name)=\(value)")
                }
            }
            if role == kAXStaticTextRole as String,
               let value = self.string(kAXValueAttribute as String, of: element), !value.isEmpty {
                parts.append("AXValue=\(value.prefix(80))")
            }
            let interesting = [kAXTextFieldRole as String, "AXSecureTextField", kAXButtonRole as String,
                               kAXWindowRole as String, kAXSheetRole as String, kAXRowRole as String]
            guard !parts.isEmpty || interesting.contains(role) else { return }
            let press = self.actions(of: element).contains(kAXPressAction as String) ? " [press]" : ""
            lines.append(String(repeating: " ", count: min(depth, 30)) + role + " "
                         + parts.joined(separator: " ") + press)
        }
        return ["lines": lines]
    }

    /// Ordinary quit of the exact PID; force only if it ignores the request.
    func quit() -> [String: Any] {
        _ = application.terminate()
        let deadline = Date().addingTimeInterval(min(timeout, 10))
        while kill(pid, 0) == 0 && Date() < deadline { usleep(100_000) }
        if kill(pid, 0) == 0 { _ = application.forceTerminate() }
        return [:]
    }
}

private func emitLive(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}

private func runLive(_ arguments: [String]) -> Int32 {
    let flagsWithValues: Set<String> = ["--pid", "--timeout", "--identifier", "--label", "--label-prefix", "--role",
                                        "--env", "--width", "--height", "--output", "--name", "--matte"]
    var values: [String: String] = [:]
    var query = LiveQuery()
    var first = false
    do {
        guard let operation = arguments.first else {
            throw LiveFailure(code: DriverError.invalidArguments.rawValue, blocked: false)
        }
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--first" { first = true; index += 1; continue }
            guard flagsWithValues.contains(flag), index + 1 < arguments.count else {
                throw LiveFailure(code: DriverError.invalidArguments.rawValue, blocked: false)
            }
            let value = arguments[index + 1]
            switch flag {
            case "--role": query.roles.append(value)
            case "--identifier": query.identifier = value
            case "--label": query.label = value
            case "--label-prefix": query.labelPrefix = value
            default:
                guard values[flag] == nil else {
                    throw LiveFailure(code: DriverError.invalidArguments.rawValue, blocked: false)
                }
                values[flag] = value
            }
            index += 2
        }
        let timeout = values["--timeout"].flatMap(TimeInterval.init) ?? 15
        guard let rawPID = values["--pid"], let pid = pid_t(rawPID), pid > 1,
              (1...120).contains(timeout) else {
            throw LiveFailure(code: DriverError.invalidArguments.rawValue, blocked: false)
        }
        let needsQuery = ["count", "wait", "press", "select-row", "focus", "action", "set-value"]
        guard !needsQuery.contains(operation) || !query.isEmpty else {
            throw LiveFailure(code: DriverError.invalidArguments.rawValue, blocked: false)
        }
        let driver = try LiveDriver(pid: pid, timeout: timeout)
        var payload: [String: Any]
        switch operation {
        case "preflight": payload = try driver.preflight()
        case "window": payload = try driver.windowInfo()
        case "activate": payload = try driver.activate()
        case "resize":
            guard let width = values["--width"].flatMap(Double.init), width > 0,
                  let height = values["--height"].flatMap(Double.init), height > 0 else {
                throw LiveFailure(code: DriverError.invalidArguments.rawValue, blocked: false)
            }
            payload = try driver.resize(width: width, height: height)
        case "count": payload = driver.count(query)
        case "wait": payload = try driver.wait(query)
        case "press": payload = try driver.press(query, first: first)
        case "select-row": payload = try driver.selectRow(query)
        case "focus": payload = try driver.focus(query)
        case "action":
            guard let name = values["--name"], !name.isEmpty else {
                throw LiveFailure(code: DriverError.invalidArguments.rawValue, blocked: false)
            }
            payload = try driver.perform(name, on: query)
        case "set-value":
            guard let name = values["--env"], !name.isEmpty else {
                throw LiveFailure(code: DriverError.invalidArguments.rawValue, blocked: false)
            }
            payload = try driver.setValue(query, environmentName: name)
        case "capture":
            guard let output = values["--output"], !output.isEmpty else {
                throw LiveFailure(code: DriverError.invalidArguments.rawValue, blocked: false)
            }
            payload = try driver.capture(to: URL(fileURLWithPath: output), matte: values["--matte"])
        case "dump": payload = driver.dump()
        case "quit": payload = driver.quit()
        default: throw LiveFailure(code: DriverError.invalidArguments.rawValue, blocked: false)
        }
        payload["status"] = "passed"
        emitLive(payload)
        return 0
    } catch {
        let failure = (error as? LiveFailure)
            ?? LiveFailure(code: DriverError.actionFailed.rawValue, blocked: false)
        var payload = failure.detail
        payload["status"] = failure.blocked ? "blocked" : "failed"
        payload["errorCode"] = failure.code
        emitLive(payload)
        fputs("agent-macos-ax-driver: live \(payload["status"] ?? "failed") code=\(failure.code)\n",
              stderr)
        return failure.blocked ? 2 : 1
    }
}

if CommandLine.arguments.dropFirst().first == "live" {
    exit(runLive(Array(CommandLine.arguments.dropFirst(2))))
}

var outputURL: URL?
var resultPID: pid_t = 0
var completedStage = "preflight"
var actionCount = 0

do {
    let arguments = try parseArguments()
    outputURL = arguments.output
    resultPID = arguments.pid
    let driver = try FixtureDriver(pid: arguments.pid, timeout: arguments.timeout)
    do {
        try driver.run(screenshotBefore: arguments.screenshotBefore,
                       screenshotAfter: arguments.screenshotAfter,
                       captureOnly: arguments.captureOnly)
        completedStage = driver.completedStage
        actionCount = driver.actionCount
    } catch {
        completedStage = driver.completedStage
        actionCount = driver.actionCount
        throw error
    }
    try write(DriverResult(schemaVersion: 1, status: "passed", pid: resultPID,
                           scenario: arguments.captureOnly ? "fixture-home-passive" : "fixture-detail",
                           completedStage: completedStage,
                           actionCount: actionCount, windowID: largestWindowID(for: resultPID),
                           errorCode: nil), to: arguments.output)
} catch {
    let code = (error as? DriverError) ?? .actionFailed
    if let outputURL {
        try? write(DriverResult(schemaVersion: 1, status: "failed", pid: resultPID,
                                scenario: "fixture-detail", completedStage: completedStage,
                                actionCount: actionCount, windowID: largestWindowID(for: resultPID),
                                errorCode: code.rawValue), to: outputURL)
    }
    fputs("agent-macos-ax-driver: failed code=\(code.rawValue)\n", stderr)
    exit(code == .accessibilityNotTrusted ? 2 : 1)
}
