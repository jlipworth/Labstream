import Foundation

/// A typed description of one shipped UserDefaults value.
struct PreferenceKey<Value> {
    let name: String
    let defaultValue: Value
    fileprivate let readValue: (UserDefaults, String) -> Value?
    fileprivate let writeValue: (UserDefaults, String, Value) -> Void

    static func bool(_ name: String, default defaultValue: Bool) -> PreferenceKey<Bool>
        where Value == Bool {
        PreferenceKey<Bool>(name: name, defaultValue: defaultValue,
                            readValue: { defaults, key in
                                defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
                            },
                            writeValue: { $0.set($2, forKey: $1) })
    }

    static func integer(_ name: String, default defaultValue: Int) -> PreferenceKey<Int>
        where Value == Int {
        PreferenceKey<Int>(name: name, defaultValue: defaultValue,
                           readValue: { defaults, key in
                               defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
                           },
                           writeValue: { $0.set($2, forKey: $1) })
    }

    static func string(_ name: String, default defaultValue: String) -> PreferenceKey<String>
        where Value == String {
        PreferenceKey<String>(name: name, defaultValue: defaultValue,
                              readValue: { $0.string(forKey: $1) },
                              writeValue: { $0.set($2, forKey: $1) })
    }
}

/// Single typed access boundary for app preferences. Shipped raw keys and defaults remain owned by
/// their feature namespaces; this store removes repeated object/type/default branching.
struct TypedPreferenceStore {
    /// User preferences are durable UX state, not transfer/recovery authority. UserDefaults may
    /// coalesce its own writes, so this boundary is explicitly best-effort.
    static let durability: PersistenceDurabilityTier = .bestEffort

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func value<Value>(for key: PreferenceKey<Value>) -> Value {
        key.readValue(defaults, key.name) ?? key.defaultValue
    }

    func set<Value>(_ value: Value, for key: PreferenceKey<Value>) {
        key.writeValue(defaults, key.name, value)
    }

    func contains<Value>(_ key: PreferenceKey<Value>) -> Bool {
        defaults.object(forKey: key.name) != nil
    }
}
