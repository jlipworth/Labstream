import Foundation
import os
import PMSKit

/// App-owned opt-in diagnostics facade.
///
/// The public app call-site API accepts only typed `DiagnosticFieldValue`s. String fields are
/// redacted again by PMSKit before they enter the bounded ring buffer. The toggle is persisted,
/// but the report buffer itself is process-local and capped so it cannot grow without bound.
enum AppDiagnostics {
    static let enabledDefaultsKey = "diagnosticLoggingEnabled"
    static let maxReportEvents = 80

    private static let subsystem = "com.jlipworth.VisionPlex"
    private static let store = DiagnosticLogStore(
        capacity: 300,
        enabled: UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    )

    static var isEnabled: Bool {
        let persisted = UserDefaults.standard.bool(forKey: enabledDefaultsKey)
        store.setEnabled(persisted)
        return persisted
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            UserDefaults.standard.set(true, forKey: enabledDefaultsKey)
            store.setEnabled(true)
            record(.settingsUI, "diagnostics.enabled", fields: ["enabled": .bool(true)])
        } else {
            store.setEnabled(true)
            record(.settingsUI, "diagnostics.disabled", fields: ["enabled": .bool(false)])
            UserDefaults.standard.set(false, forKey: enabledDefaultsKey)
            store.setEnabled(false)
        }
    }

    static func clear() {
        store.clear()
    }

    @discardableResult
    static func record(_ category: DiagnosticCategory,
                       _ name: String,
                       fields: [String: DiagnosticFieldValue] = [:]) -> DiagnosticEvent? {
        store.setEnabled(UserDefaults.standard.bool(forKey: enabledDefaultsKey))
        guard let event = store.record(category: category, name: name, fields: fields) else {
            return nil
        }
        logger(for: category).debug("\(event.summaryLine, privacy: .public)")
        return event
    }

    static func events(limit: Int? = nil) -> [DiagnosticEvent] {
        store.snapshot(limit: limit)
    }

    static func report(context: DiagnosticReportContext) -> String {
        DiagnosticReportRenderer.render(context: context,
                                        events: store.snapshot(),
                                        maxEvents: maxReportEvents)
    }

    private static func logger(for category: DiagnosticCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.logCategory)
    }
}
