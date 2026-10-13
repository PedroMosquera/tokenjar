import Foundation

/// Reads and writes one preferences key at a time. `UserDefaults` conforms; tests use a dictionary.
public protocol DefaultsStoring: DefaultsReading {
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: DefaultsStoring {}

/// Whether Check provider status pages is on for this Mac. It lives in Tokenjar's preferences domain and never in
/// config.json: that file can be shared between Macs, and turning this on must not make another Mac contact status
/// hosts.
public struct ProviderHealthSetting {
    public static let key = "providerStatus"

    private let defaults: any DefaultsStoring

    public init(defaults: any DefaultsStoring) {
        self.defaults = defaults
    }

    /// Off until turned on, so an update never starts contacting status hosts by itself.
    public var isOn: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}
