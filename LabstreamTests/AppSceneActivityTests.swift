#if !os(tvOS)
import SwiftUI
import Testing
@testable import Labstream

@Suite("App scene activity aggregate")
@MainActor
struct AppSceneActivityTests {
    @MainActor
    private final class TestScheduler {
        private final class Entry {
            let operation: @MainActor () -> Void
            var isCancelled = false

            init(operation: @escaping @MainActor () -> Void) {
                self.operation = operation
            }
        }

        private var entries: [Entry] = []

        func schedule(_ operation: @escaping @MainActor () -> Void)
            -> AppSceneActivity.ScheduledTransition {
            let entry = Entry(operation: operation)
            entries.append(entry)
            return AppSceneActivity.ScheduledTransition {
                entry.isCancelled = true
            }
        }

        func runScheduledTransitions() {
            let scheduled = entries
            entries.removeAll()
            for entry in scheduled where !entry.isCancelled {
                entry.operation()
            }
        }
    }

    private final class EdgeRecorder {
        var values: [Bool] = []
    }

    private func makeActivity(_ edges: EdgeRecorder, scheduler: TestScheduler)
        -> AppSceneActivity {
        AppSceneActivity(scheduleInactivity: scheduler.schedule) {
            edges.values.append($0)
        }
    }

    @Test
    func duplicateSceneEventsPublishOnlyAggregateEdges() {
        let edges = EdgeRecorder()
        let scheduler = TestScheduler()
        let activity = makeActivity(edges, scheduler: scheduler)
        let main = UUID()

        activity.report(sourceID: main, role: .mainWindow, phase: .active)
        activity.report(sourceID: main, role: .mainWindow, phase: .active)
        activity.report(sourceID: main, role: .mainWindow, phase: .inactive)
        activity.report(sourceID: main, role: .mainWindow, phase: .background)
        scheduler.runScheduledTransitions()
        activity.report(sourceID: main, role: .mainWindow, phase: .active)

        #expect(edges.values == [true, false, true])
    }

    @Test
    func cinemaEntryKeepsForegroundTruthWhileMainWindowLeaves() {
        let edges = EdgeRecorder()
        let scheduler = TestScheduler()
        let activity = makeActivity(edges, scheduler: scheduler)
        let main = UUID()
        let cinema = UUID()

        activity.report(sourceID: main, role: .mainWindow, phase: .active)
        activity.report(sourceID: cinema, role: .cinemaImmersive, phase: .active)
        activity.report(sourceID: main, role: .mainWindow, phase: .inactive)
        activity.remove(sourceID: main)
        scheduler.runScheduledTransitions()

        #expect(activity.isActive)
        #expect(edges.values == [true])
    }

    @Test
    func cinemaExitKeepsForegroundTruthWhileImmersiveSceneLeaves() {
        let edges = EdgeRecorder()
        let scheduler = TestScheduler()
        let activity = makeActivity(edges, scheduler: scheduler)
        let cinema = UUID()
        let main = UUID()

        activity.report(sourceID: cinema, role: .cinemaImmersive, phase: .active)
        activity.report(sourceID: main, role: .mainWindow, phase: .active)
        activity.report(sourceID: cinema, role: .cinemaImmersive, phase: .background)
        activity.remove(sourceID: cinema)
        scheduler.runScheduledTransitions()

        #expect(activity.isActive)
        #expect(edges.values == [true])
    }

    @Test
    func zeroSceneReplacementGapDoesNotInventBackgroundTransition() {
        let edges = EdgeRecorder()
        let scheduler = TestScheduler()
        let activity = makeActivity(edges, scheduler: scheduler)
        let oldMain = UUID()
        let replacement = UUID()

        activity.report(sourceID: oldMain, role: .mainWindow, phase: .active)
        activity.remove(sourceID: oldMain)
        activity.report(sourceID: replacement, role: .cinemaImmersive, phase: .active)
        scheduler.runScheduledTransitions()
        activity.report(sourceID: replacement, role: .cinemaImmersive, phase: .inactive)
        scheduler.runScheduledTransitions()

        #expect(!activity.isActive)
        #expect(edges.values == [true, false])
    }

    @Test
    func settingsKeepsMacActiveAfterMainWindowBecomesInactive() {
        let edges = EdgeRecorder()
        let scheduler = TestScheduler()
        let activity = makeActivity(edges, scheduler: scheduler)
        let main = UUID()
        let settings = UUID()

        activity.report(sourceID: main, role: .mainWindow, phase: .active)
        activity.report(sourceID: settings, role: .settings, phase: .active)
        activity.report(sourceID: main, role: .mainWindow, phase: .inactive)
        activity.remove(sourceID: main)
        activity.report(sourceID: settings, role: .settings, phase: .background)
        scheduler.runScheduledTransitions()

        #expect(!activity.isActive)
        #expect(edges.values == [true, false])
    }

    @Test
    func inactiveSourceCannotOverrideAnotherActiveSource() {
        let edges = EdgeRecorder()
        let scheduler = TestScheduler()
        let activity = makeActivity(edges, scheduler: scheduler)
        let main = UUID()
        let cinema = UUID()

        activity.report(sourceID: main, role: .mainWindow, phase: .background)
        activity.report(sourceID: cinema, role: .cinemaImmersive, phase: .active)
        activity.report(sourceID: main, role: .mainWindow, phase: .inactive)
        scheduler.runScheduledTransitions()

        #expect(activity.isActive)
        #expect(edges.values == [true])
    }

    @Test
    func outgoingSceneCanReportInactiveBeforeSuccessorBecomesActive() {
        let edges = EdgeRecorder()
        let scheduler = TestScheduler()
        let activity = makeActivity(edges, scheduler: scheduler)
        let main = UUID()
        let cinema = UUID()

        activity.report(sourceID: main, role: .mainWindow, phase: .active)
        activity.report(sourceID: main, role: .mainWindow, phase: .inactive)
        activity.report(sourceID: main, role: .mainWindow, phase: .background)
        activity.report(sourceID: cinema, role: .cinemaImmersive, phase: .active)
        scheduler.runScheduledTransitions()

        #expect(activity.isActive)
        #expect(edges.values == [true])
    }

    @Test
    func removingLastActiveSourceEventuallyPublishesInactiveWithoutSuccessor() {
        let edges = EdgeRecorder()
        let scheduler = TestScheduler()
        let activity = makeActivity(edges, scheduler: scheduler)
        let main = UUID()

        activity.report(sourceID: main, role: .mainWindow, phase: .active)
        activity.remove(sourceID: main)

        #expect(activity.isActive)
        #expect(edges.values == [true])

        scheduler.runScheduledTransitions()

        #expect(!activity.isActive)
        #expect(edges.values == [true, false])
    }
}
#endif
