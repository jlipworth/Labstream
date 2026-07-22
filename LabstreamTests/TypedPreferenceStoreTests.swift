import Foundation
import Testing
@testable import Labstream

@Suite("Typed preference store")
struct TypedPreferenceStoreTests {
    @Test
    func preferencesAreExplicitlyBestEffortState() {
        #expect(TypedPreferenceStore.durability == .bestEffort)
    }

    @Test
    func returnsTypedDefaultsAndRoundTripsValuesWithoutChangingRawKeys() {
        let suiteName = "TypedPreferenceStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TypedPreferenceStore(defaults: defaults)
        let enabled = PreferenceKey<Bool>.bool("shipped.bool", default: true)
        let count = PreferenceKey<Int>.integer("shipped.int", default: 7)
        let label = PreferenceKey<String>.string("shipped.string", default: "original")

        #expect(store.value(for: enabled))
        #expect(store.value(for: count) == 7)
        #expect(store.value(for: label) == "original")
        #expect(!store.contains(enabled))

        store.set(false, for: enabled)
        store.set(11, for: count)
        store.set("saved", for: label)

        #expect(defaults.object(forKey: "shipped.bool") as? Bool == false)
        #expect(store.value(for: count) == 11)
        #expect(store.value(for: label) == "saved")
    }

    @Test
    func playbackPreferenceDefaultsAndLegacyRemoteFallbackRemainStable() {
        let suiteName = "TypedPlaybackPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PlaybackPreferences.autoPlayUpNext(defaults: defaults))
        #expect(PlaybackPreferences.qualityKbps(
            forDefaultsKey: PlaybackPreferences.Keys.remoteQualityKbps,
            defaults: defaults
        ) == PlaybackPreferences.defaultRemoteQualityKbps)

        defaults.set(3_500, forKey: PlaybackPreferences.Keys.legacyQualityKbps)
        #expect(PlaybackPreferences.qualityKbps(
            forDefaultsKey: PlaybackPreferences.Keys.remoteQualityKbps,
            defaults: defaults
        ) == 3_500)
    }
}
