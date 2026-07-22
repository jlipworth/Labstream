#!/usr/bin/env -S xcrun swift

import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation

private let toolName = "labstream-macos-ax-driver"
private let toolVersion = 1
private let fixedUsername = "benchmark-user"
private let fixedPassword = "benchmark-pass-v1"

private enum DriverError: String, Error {
    case invalidArguments = "invalid_arguments"
    case invalidOutput = "invalid_output"
    case invalidSpecFile = "invalid_spec_file"
    case invalidSpecPermissions = "invalid_spec_permissions"
    case invalidSpecSchema = "invalid_spec_schema"
    case invalidFixtureURL = "invalid_fixture_url"
    case invalidFixtureCredentials = "invalid_fixture_credentials"
    case invalidPID = "invalid_pid"
    case processUnavailable = "process_unavailable"
    case accessibilityNotTrusted = "accessibility_not_trusted"
    case elementNotFound = "element_not_found"
    case elementAmbiguous = "element_ambiguous"
    case accessibilityReadFailed = "accessibility_read_failed"
    case accessibilityActionFailed = "accessibility_action_failed"
    case keyboardActionFailed = "keyboard_action_failed"
    case outputWriteFailed = "output_write_failed"
}

private enum Scenario: String, Codable, CaseIterable {
    case home, catalog, search, artwork
}

private struct WorkloadSpec: Codable {
    let schemaVersion: Int
    let baseURL: String
    let username: String
    let password: String
    let scenario: Scenario
    let timeoutSeconds: Double

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case baseURL = "base_url"
        case username, password, scenario
        case timeoutSeconds = "timeout_seconds"
    }
}

private struct DriverResult: Codable {
    let schemaVersion: Int
    let tool: Tool
    let pid: Int32
    let scenario: String
    let status: String
    let completedStage: String
    let actionCount: Int
    let elapsedMilliseconds: Int
    let errorCode: String?

    struct Tool: Codable { let name: String; let version: Int }
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case tool, pid, scenario, status
        case completedStage = "completed_stage"
        case actionCount = "action_count"
        case elapsedMilliseconds = "elapsed_milliseconds"
        case errorCode = "error_code"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(tool, forKey: .tool)
        try container.encode(pid, forKey: .pid)
        try container.encode(scenario, forKey: .scenario)
        try container.encode(status, forKey: .status)
        try container.encode(completedStage, forKey: .completedStage)
        try container.encode(actionCount, forKey: .actionCount)
        try container.encode(elapsedMilliseconds, forKey: .elapsedMilliseconds)
        if let errorCode {
            try container.encode(errorCode, forKey: .errorCode)
        } else {
            try container.encodeNil(forKey: .errorCode)
        }
    }
}

private struct Arguments {
    let pid: pid_t
    let spec: URL
    let output: URL
}

private func parseArguments() throws -> Arguments {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 6 else { throw DriverError.invalidArguments }
    var values: [String: String] = [:]
    var index = 0
    while index < args.count {
        let flag = args[index]
        guard ["--pid", "--workload-spec", "--output"].contains(flag),
              values[flag] == nil, index + 1 < args.count else {
            throw DriverError.invalidArguments
        }
        values[flag] = args[index + 1]
        index += 2
    }
    guard let pidText = values["--pid"], let pid = Int32(pidText), pid > 1,
          let spec = values["--workload-spec"], !spec.isEmpty,
          let output = values["--output"], !output.isEmpty else {
        throw DriverError.invalidArguments
    }
    return Arguments(pid: pid, spec: URL(fileURLWithPath: spec), output: URL(fileURLWithPath: output))
}

private func readSpec(_ url: URL) throws -> WorkloadSpec {
    var info = stat()
    guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
          info.st_uid == geteuid() else { throw DriverError.invalidSpecFile }
    guard info.st_mode & 0o077 == 0 else { throw DriverError.invalidSpecPermissions }
    let data: Data
    do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
    catch { throw DriverError.invalidSpecFile }
    guard data.count <= 16_384,
          let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(document.keys) == Set(WorkloadSpec.CodingKeys.allCases.map(\.rawValue)),
          let spec = try? JSONDecoder().decode(WorkloadSpec.self, from: data),
          spec.schemaVersion == 1,
          spec.timeoutSeconds >= 1, spec.timeoutSeconds <= 120 else {
        throw DriverError.invalidSpecSchema
    }
    guard spec.username == fixedUsername, spec.password == fixedPassword else {
        throw DriverError.invalidFixtureCredentials
    }
    guard let components = URLComponents(string: spec.baseURL),
          components.scheme == "http", components.host == "127.0.0.1",
          let port = components.port, (1...65535).contains(port),
          components.user == nil, components.password == nil,
          (components.path.isEmpty || components.path == "/"),
          components.query == nil, components.fragment == nil else {
        throw DriverError.invalidFixtureURL
    }
    return spec
}

private func validateOutput(_ url: URL) throws {
    var info = stat()
    if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG {
        throw DriverError.invalidOutput
    }
    var parentInfo = stat()
    guard lstat(url.deletingLastPathComponent().path, &parentInfo) == 0,
          (parentInfo.st_mode & S_IFMT) == S_IFDIR else { throw DriverError.invalidOutput }
}

private func writeResult(_ result: DriverResult, to url: URL) throws {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(result)
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else { throw DriverError.outputWriteFailed }
    } catch let error as DriverError { throw error }
      catch { throw DriverError.outputWriteFailed }
}

private enum Attribute: String {
    case role = "AXRole"
    case title = "AXTitle"
    case description = "AXDescription"
    case identifier = "AXIdentifier"
    case placeholder = "AXPlaceholderValue"
    case children = "AXChildren"
    case enabled = "AXEnabled"
    case focused = "AXFocused"
    case parent = "AXParent"
    case selected = "AXSelected"
    case value = "AXValue"
}

private struct Query {
    let roles: Set<String>
    let strings: [Attribute: Set<String>]
    let requiresEnabled: Bool

    init(roles: [String], attribute: Attribute, values: [String], requiresEnabled: Bool = true) {
        self.roles = Set(roles)
        self.strings = [attribute: Set(values)]
        self.requiresEnabled = requiresEnabled
    }

    init(roles: [String], strings: [Attribute: [String]], requiresEnabled: Bool = true) {
        self.roles = Set(roles)
        self.strings = strings.mapValues(Set.init)
        self.requiresEnabled = requiresEnabled
    }
}

private final class AccessibilityDriver {
    private let pid: pid_t
    private let root: AXUIElement
    private let timeout: TimeInterval
    private(set) var actionCount = 0
    private(set) var completedStage = "attached"

    init(pid: pid_t, timeout: TimeInterval) throws {
        guard kill(pid, 0) == 0 else {
            throw DriverError.processUnavailable
        }
        let registrationDeadline = Date().addingTimeInterval(min(timeout, 5))
        var registeredApplication: NSRunningApplication?
        repeat {
            registeredApplication = NSRunningApplication(processIdentifier: pid)
            if registeredApplication == nil { usleep(50_000) }
        } while registeredApplication == nil && Date() < registrationDeadline && kill(pid, 0) == 0
        guard let application = registeredApplication else { throw DriverError.processUnavailable }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: false] as CFDictionary) else {
            throw DriverError.accessibilityNotTrusted
        }
        let activationDeadline = Date().addingTimeInterval(min(timeout, 5))
        var activated = false
        repeat {
            activated = application.isActive || application.activate(options: [.activateAllWindows])
            if !activated { usleep(50_000) }
        } while !activated && Date() < activationDeadline && kill(pid, 0) == 0
        guard activated else { throw DriverError.accessibilityActionFailed }
        self.pid = pid
        self.root = AXUIElementCreateApplication(pid)
        self.timeout = timeout
    }

    func run(_ spec: WorkloadSpec) throws {
        try authenticate(spec)
        switch spec.scenario {
        case .home:
            try waitForHome(stage: "home_loaded")
        case .catalog:
            try openCatalog()
            try waitForIdentifier("performance.mac.library-grid.first-item", stage: "catalog_loaded")
        case .search:
            try openSearch()
            try waitForIdentifier("performance.mac.search-results.first-group", stage: "search_loaded")
        case .artwork:
            try openCatalog()
            try waitForIdentifier("performance.mac.library-grid.first-item", stage: "artwork_requested")
        }
    }

    private func authenticate(_ spec: WorkloadSpec) throws {
        try press(Query(roles: [kAXRadioButtonRole as String, kAXButtonRole as String],
                        attribute: .description, values: ["Emby"]),
                  fallback: Query(roles: [kAXRadioButtonRole as String, kAXButtonRole as String],
                                  attribute: .title, values: ["Emby"]),
                  stage: "backend_selected")
        try press(Query(roles: [kAXButtonRole as String], attribute: .identifier,
                        values: ["performance.login.emby.server-url-method"]),
                  fallback: Query(roles: [kAXButtonRole as String], attribute: .title,
                                  values: ["Sign in with server URL"]),
                  stage: "credential_method_selected")
        try setValue(spec.baseURL, query: Query(
            roles: [kAXTextFieldRole as String], attribute: .identifier,
            values: ["performance.login.emby.server-url"]),
                     fallback: Query(roles: [kAXTextFieldRole as String], attribute: .placeholder,
                                     values: ["https://emby.example.com"]),
                     stage: "server_entered")
        try setValue(spec.username, query: Query(
            roles: [kAXTextFieldRole as String], attribute: .identifier,
            values: ["performance.login.emby.username"]),
                     fallback: Query(roles: [kAXTextFieldRole as String], attribute: .placeholder,
                                     values: ["Username"]), stage: "username_entered")
        try setValue(spec.password, query: Query(
            roles: [kAXTextFieldRole as String],
            attribute: .identifier, values: ["performance.login.emby.password"]),
                     fallback: Query(roles: [kAXTextFieldRole as String], attribute: .placeholder,
                                     values: ["Password"]),
                     stage: "password_entered")
        try press(Query(roles: [kAXButtonRole as String], attribute: .identifier,
                        values: ["performance.login.emby.sign-in"]),
                  fallback: Query(roles: [kAXButtonRole as String], attribute: .title,
                                  values: ["Sign in with Emby"]), stage: "sign_in_submitted")

        // The first-login library visibility sheet is allowed, but never required. More than
        // one exact match is a hard ambiguity just like every required selector.
        completedStage = "awaiting_visibility_or_home"
        try dismissVisibilityOrWaitForHome()
        try waitForHome(stage: "authenticated")
    }

    private func openCatalog() throws {
        // SwiftUI exposes each selectable source-list label as AXStaticText. Both libraries share
        // the privacy-safe identifier, while the accessibility label is AXValue; require both so
        // the synthetic Movies row remains exact and duplicate-safe.
        let label = try requiredElement(Query(roles: [kAXStaticTextRole as String], strings: [
            .identifier: ["performance.mac.sidebar.library"],
            .value: ["Fixture Movies"],
        ]))
        var candidate = label
        for _ in 0..<4 {
            if case .success(let rawRole) = copy(.role, from: candidate),
               rawRole as? String == kAXRowRole as String {
                guard AXUIElementSetAttributeValue(candidate,
                                                   Attribute.selected.rawValue as CFString,
                                                   kCFBooleanTrue) == .success else {
                    throw DriverError.accessibilityActionFailed
                }
                actionCount += 1
                completedStage = "catalog_opened"
                return
            }
            guard case .success(let rawParent) = copy(.parent, from: candidate),
                  CFGetTypeID(rawParent) == AXUIElementGetTypeID() else {
                throw DriverError.accessibilityReadFailed
            }
            candidate = unsafeBitCast(rawParent, to: AXUIElement.self)
        }
        throw DriverError.elementNotFound
    }

    private func openSearch() throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: false) else {
            throw DriverError.keyboardActionFailed
        }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
        actionCount += 1
        completedStage = "search_opened"
        let field = try requiredElement(Query(
            roles: [kAXTextFieldRole as String], attribute: .identifier,
            values: ["performance.mac.search-field"]), fallback: Query(
            roles: [kAXTextFieldRole as String],
            attribute: .placeholder, values: ["Movies, shows, music…"]))
        try performSet(fixedSearchQuery, on: field)
        actionCount += 1
        completedStage = "search_entered"
    }

    private let fixedSearchQuery = "Z Fixture"

    private var homeMilestoneQuery: Query {
        // SwiftUI propagates a composite rail's identifier to its title, View All button,
        // and horizontal scroll area. The scroll area is the single structural owner.
        Query(roles: [kAXScrollAreaRole as String], attribute: .identifier,
              values: ["performance.mac.home.first-rail"], requiresEnabled: false)
    }

    private var homeTitleFallback: Query {
        Query(roles: [kAXStaticTextRole as String], attribute: .value,
              values: ["Continue Watching"], requiresEnabled: false)
    }

    private func waitForHome(stage: String) throws {
        _ = try requiredElement(homeMilestoneQuery, fallback: homeTitleFallback)
        completedStage = stage
    }

    private func dismissVisibilityOrWaitForHome() throws {
        let visibilityIdentifier = Query(roles: [kAXButtonRole as String], attribute: .identifier,
                                         values: ["performance.library-visibility.not-now"])
        let visibilityLabel = Query(roles: [kAXButtonRole as String], attribute: .title,
                                    values: ["Not Now"])
        let deadline = Date().addingTimeInterval(timeout)
        var homeFirstSeen: Date?
        repeat {
            for query in [visibilityIdentifier, visibilityLabel] {
                let matches = try matching(query)
                if matches.count == 1 {
                    try perform(kAXPressAction as String, on: matches[0])
                    actionCount += 1
                    return
                }
                if matches.count > 1 {
                    completedStage = "visibility_ambiguous"
                    throw DriverError.elementAmbiguous
                }
            }
            // The browse hierarchy can already exist behind the first-run sheet. Only accept
            // Home after a bounded absence window proves the modal did not arrive just after
            // the underlying browse hierarchy became visible.
            var foundHome = false
            for query in [homeMilestoneQuery, homeTitleFallback] {
                let matches = try matching(query)
                if matches.count == 1 { foundHome = true; break }
                if matches.count > 1 {
                    completedStage = "home_ambiguous"
                    throw DriverError.elementAmbiguous
                }
            }
            if foundHome {
                let firstSeen = homeFirstSeen ?? Date()
                homeFirstSeen = firstSeen
                if Date().timeIntervalSince(firstSeen) >= 0.5 { return }
            } else {
                homeFirstSeen = nil
            }
            usleep(50_000)
        } while Date() < deadline
        throw DriverError.elementNotFound
    }

    private func waitForIdentifier(_ identifier: String, stage: String) throws {
        _ = try requiredElement(Query(
            roles: [kAXStaticTextRole as String, kAXButtonRole as String, kAXGroupRole as String,
                    kAXRowRole as String], attribute: .identifier, values: [identifier],
            requiresEnabled: false))
        completedStage = stage
    }

    private func press(_ query: Query, fallback: Query? = nil, stage: String) throws {
        let element = try requiredElement(query, fallback: fallback)
        try perform(kAXPressAction as String, on: element)
        actionCount += 1
        completedStage = stage
    }

    private func setValue(_ value: String, query: Query, fallback: Query? = nil,
                          stage: String) throws {
        let element = try requiredElement(query, fallback: fallback)
        try performSet(value, on: element)
        actionCount += 1
        completedStage = stage
    }

    private func requiredElement(_ query: Query) throws -> AXUIElement {
        try requiredElement(query, fallback: nil)
    }

    private func requiredElement(_ query: Query, fallback: Query?) throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let matches = try matching(query)
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { throw DriverError.elementAmbiguous }
            if let fallback {
                let fallbackMatches = try matching(fallback)
                if fallbackMatches.count == 1 { return fallbackMatches[0] }
                if fallbackMatches.count > 1 { throw DriverError.elementAmbiguous }
            }
            usleep(50_000)
        } while Date() < deadline
        throw DriverError.elementNotFound
    }

    private func matching(_ query: Query) throws -> [AXUIElement] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var offset = 0
        var visited = Set<CFHashCode>()
        var matches: [AXUIElement] = []
        while offset < queue.count {
            guard queue.count <= 10_000 else { throw DriverError.accessibilityReadFailed }
            let (element, depth) = queue[offset]; offset += 1
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            if try isMatch(element, query) { matches.append(element) }
            guard depth < 40 else { continue }
            switch copy(Attribute.children, from: element) {
            case .success(let value):
                if let children = value as? [AXUIElement] {
                    queue.append(contentsOf: children.map { ($0, depth + 1) })
                }
            case .unsupported: break
            case .failure: throw DriverError.accessibilityReadFailed
            }
        }
        return matches
    }

    private func isMatch(_ element: AXUIElement, _ query: Query) throws -> Bool {
        guard case .success(let roleValue) = copy(.role, from: element),
              let role = roleValue as? String, query.roles.contains(role) else { return false }
        if query.requiresEnabled,
           case .success(let enabledValue) = copy(.enabled, from: element),
           let enabled = enabledValue as? Bool, !enabled { return false }
        for (attribute, accepted) in query.strings {
            guard case .success(let raw) = copy(attribute, from: element),
                  let string = raw as? String, accepted.contains(string) else { return false }
        }
        return true
    }

    private enum CopyResult { case success(CFTypeRef), unsupported, failure }
    private func copy(_ attribute: Attribute, from element: AXUIElement) -> CopyResult {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
        if error == .success, let value { return .success(value) }
        if error == .attributeUnsupported || error == .noValue { return .unsupported }
        // SwiftUI replaces whole subtrees during authentication and modal transitions. A queued
        // element can become invalid between its role and children reads; skip that stale snapshot
        // and let the bounded outer poll traverse the new tree rather than failing the workload.
        if error == .cannotComplete || error == .invalidUIElement { return .unsupported }
        return .failure
    }

    private func perform(_ action: String, on element: AXUIElement) throws {
        guard AXUIElementPerformAction(element, action as CFString) == .success else {
            throw DriverError.accessibilityActionFailed
        }
    }

    private func performSet(_ value: String, on element: AXUIElement) throws {
        guard AXUIElementSetAttributeValue(element, Attribute.focused.rawValue as CFString,
                                           kCFBooleanTrue) == .success,
              AXUIElementSetAttributeValue(element, Attribute.value.rawValue as CFString,
                                           value as CFString) == .success else {
            throw DriverError.accessibilityActionFailed
        }
    }
}

private let started = Date()
var outputURL: URL?
var resultPID: Int32 = 0
var resultScenario = "unknown"
var completedStage = "preflight"
var actionCount = 0

do {
    let arguments = try parseArguments()
    outputURL = arguments.output
    resultPID = arguments.pid
    try validateOutput(arguments.output)
    let spec = try readSpec(arguments.spec)
    resultScenario = spec.scenario.rawValue
    guard arguments.pid != getpid() else { throw DriverError.invalidPID }
    let driver = try AccessibilityDriver(pid: arguments.pid, timeout: spec.timeoutSeconds)
    do {
        try driver.run(spec)
        completedStage = driver.completedStage; actionCount = driver.actionCount
    } catch {
        completedStage = driver.completedStage; actionCount = driver.actionCount
        throw error
    }
    let result = DriverResult(schemaVersion: 1, tool: .init(name: toolName, version: toolVersion),
                              pid: resultPID, scenario: resultScenario, status: "success",
                              completedStage: completedStage, actionCount: actionCount,
                              elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                              errorCode: nil)
    try writeResult(result, to: arguments.output)
} catch {
    let code = (error as? DriverError) ?? .accessibilityActionFailed
    if let outputURL {
        let result = DriverResult(schemaVersion: 1, tool: .init(name: toolName, version: toolVersion),
                                  pid: resultPID, scenario: resultScenario, status: "failure",
                                  completedStage: completedStage, actionCount: actionCount,
                                  elapsedMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
                                  errorCode: code.rawValue)
        try? writeResult(result, to: outputURL)
    }
    fputs("perf-macos-ax-driver: failed code=\(code.rawValue)\n", stderr)
    exit(1)
}
