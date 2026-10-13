import Foundation
import Testing
@testable import TokenjarCore

/// A preferences domain in memory.
final class DictionaryDefaults: DefaultsStoring {
    var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

struct ProviderHealthSettingTests {
    /// Every install was promised one request of its own; status hosts are contacted only on a Mac where it was turned on.
    @Test func providerStatusIsOffByDefault() {
        #expect(!ProviderHealthSetting(defaults: DictionaryDefaults()).isOn)
    }

    @Test func turningItOnWritesOnlyItsOwnKey() {
        let defaults = DictionaryDefaults()
        let setting = ProviderHealthSetting(defaults: defaults)
        setting.isOn = true
        #expect(defaults.values.keys.sorted() == ["providerStatus"])
        #expect(defaults.values["providerStatus"] as? Bool == true)
        #expect(ProviderHealthSetting(defaults: defaults).isOn)
        setting.isOn = false
        #expect(!ProviderHealthSetting(defaults: defaults).isOn)
    }
}
