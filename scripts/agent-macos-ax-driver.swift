#!/usr/bin/env -S xcrun swift

import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation

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
