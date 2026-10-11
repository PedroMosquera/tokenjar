import Foundation
import Security
import Testing
@testable import TokenjarCore

/// Builds queries only. Nothing here reads or writes the Keychain.
struct KeychainSecretStoreTests {
    /// Hard rule 2. Literals rather than AppPaths.keychainService, so renaming the constant also fails here.
    @Test func everyQueryIsScopedToTheAppsOwnService() {
        let store = KeychainSecretStore()
        #expect(store.service == "com.pedromosquera.headroom.apikeys")

        let query = store.query("go")

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "com.pedromosquera.headroom.apikeys")
        #expect(query[kSecAttrAccount as String] as? String == "go")
        #expect(query.count == 3, "a wider match (search list, access group) needs a reviewed edit here")
    }
}
