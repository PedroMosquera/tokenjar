import Foundation
import Security
import Testing
@testable import TokenjarCore

/// Builds queries only. Nothing here reads or writes the Keychain.
struct KeychainSecretStoreTests {
    /// Hard rule 2. Literals rather than AppPaths.keychainService, so renaming the constant also fails here.
    @Test func everyQueryIsScopedToTheAppsOwnService() {
        let store = KeychainSecretStore()
        #expect(store.service == "com.pedromosquera.tokenjar.apikeys")

        let query = store.query("go")

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "com.pedromosquera.tokenjar.apikeys")
        #expect(query[kSecAttrAccount as String] as? String == "go")
        #expect(query.count == 3, "a wider match (search list, access group) needs a reviewed edit here")
    }

    @Test func aNewKeyIsLabelledWithTheAppsName() {
        let query = KeychainSecretStore().addQuery("go", data: Data("k".utf8))

        #expect(query[kSecAttrService as String] as? String == "com.pedromosquera.tokenjar.apikeys")
        #expect(query[kSecAttrLabel as String] as? String == "Tokenjar API key")
        #expect(query.count == 5, "an add query wider than service, account, value and label needs a reviewed edit here")
    }
}

/// What SecItemCopyMatching returns when the user is asked and says no: Deny on the access prompt (errSecAuthFailed),
/// Cancel on an unlock prompt (errSecUserCanceled), or no way to ask at all.
struct SecretStoreRefusalTests {
    @Test(arguments: [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecInteractionRequired])
    func aRefusedReadIsARefusal(status: OSStatus) {
        #expect(SecretStoreError.keychain(status).isRefusal)
    }

    @Test(arguments: [errSecItemNotFound, errSecDecode, errSecParam, errSecNotAvailable])
    func otherFailuresAreNot(status: OSStatus) {
        #expect(!SecretStoreError.keychain(status).isRefusal)
    }
}

/// Each read of the real store can put a Keychain prompt on screen, so these count reads of a fake one.
struct SessionSecretStoreTests {
    @Test func aKeyIsReadFromTheKeychainOncePerLaunch() throws {
        let keychain = CountingSecretStore(["go": "sk-placeholder"])
        let session = SessionSecretStore(keychain)

        for _ in 0..<5 { #expect(try session.read(account: "go") == "sk-placeholder") }
        for _ in 0..<3 { #expect(try session.read(account: "other") == nil) }

        #expect(keychain.readCount("go") == 1)
        #expect(keychain.readCount("other") == 1)
    }

    @Test func aRefusalIsNotAskedAgainUntilTheUserChecks() throws {
        let keychain = CountingSecretStore(["go": "sk-placeholder"])
        keychain.refuse(with: errSecAuthFailed)
        let session = SessionSecretStore(keychain)

        for _ in 0..<4 {
            #expect(throws: SecretStoreError.self) { try session.read(account: "go") }
        }
        #expect(keychain.readCount("go") == 1)

        keychain.refuse(with: nil)
        session.allowRead(account: "go")
        #expect(try session.read(account: "go") == "sk-placeholder")
        #expect(try session.read(account: "go") == "sk-placeholder")
        #expect(keychain.readCount("go") == 2)
    }

    /// Every read can prompt again for a user who chose Allow rather than Always Allow.
    @Test func aCheckDoesNotAskAgainForAKeyItHolds() throws {
        let keychain = CountingSecretStore(["go": "sk-placeholder"])
        let session = SessionSecretStore(keychain)

        _ = try session.read(account: "go")
        session.allowRead(account: "go")
        #expect(try session.read(account: "go") == "sk-placeholder")
        #expect(keychain.readCount("go") == 1)
    }

    @Test func savingReplacesTheHeldKeyWithoutReadingItBack() throws {
        let keychain = CountingSecretStore(["go": "sk-old"])
        keychain.refuse(with: errSecUserCanceled)
        let session = SessionSecretStore(keychain)
        #expect(throws: SecretStoreError.self) { try session.read(account: "go") }

        try session.write("sk-new", account: "go")

        #expect(try session.read(account: "go") == "sk-new")
        #expect(keychain.readCount("go") == 1)
        #expect(keychain.value("go") == "sk-new")
    }

    @Test func aFailedSaveKeepsTheHeldKey() throws {
        let keychain = CountingSecretStore(["go": "sk-old"])
        let session = SessionSecretStore(keychain)
        _ = try session.read(account: "go")
        keychain.failWrites(with: errSecAuthFailed)

        #expect(throws: SecretStoreError.self) { try session.write("sk-new", account: "go") }

        #expect(try session.read(account: "go") == "sk-old")
        #expect(keychain.readCount("go") == 1)
    }

    @Test func deletingForgetsTheKeyWithoutAskingAgain() throws {
        let keychain = CountingSecretStore(["go": "sk-placeholder"])
        let session = SessionSecretStore(keychain)
        _ = try session.read(account: "go")

        try session.delete(account: "go")

        #expect(try session.read(account: "go") == nil)
        #expect(keychain.readCount("go") == 1)
        #expect(keychain.value("go") == nil)
    }

    /// Two accounts can name the same item, and their checks run in parallel.
    /// Threads rather than tasks, so the overlap does not depend on the width of the cooperative pool.
    @Test func readsThatOverlapAskTheKeychainOnce() throws {
        let keychain = CountingSecretStore(["go": "sk-placeholder"])
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), started = DispatchSemaphore(value: 0)
        keychain.duringRead = { entered.signal(); release.wait() }
        let session = SessionSecretStore(keychain)
        let lock = NSLock(), done = DispatchGroup()
        nonisolated(unsafe) var keys: [String?] = []
        func startReader() {
            done.enter()
            Thread {
                started.signal()
                let key = try? session.read(account: "go")
                lock.withLock { keys.append(key) }
                done.leave()
            }.start()
        }

        startReader()
        try #require(entered.wait(timeout: .now() + 10) == .success)
        keychain.duringRead = nil
        // The first read now waits on its prompt before storing what it found, so each later read finds nothing held and
        // queues behind it.
        for _ in 0..<5 { startReader() }
        for _ in 0..<6 { started.wait() }
        Thread.sleep(forTimeInterval: 0.1)
        release.signal()

        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(lock.withLock { keys } == Array(repeating: "sk-placeholder", count: 6))
        #expect(keychain.readCount("go") == 1)
    }

    /// A read can wait on a prompt for as long as the user leaves it; a key saved meanwhile is the one to keep.
    @Test func aKeySavedWhileAReadWaitsIsKept() throws {
        let keychain = CountingSecretStore(["go": "sk-old"])
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        keychain.duringRead = { entered.signal(); release.wait() }
        let session = SessionSecretStore(keychain)

        nonisolated(unsafe) var readerKey: String?
        DispatchQueue.global().async {
            readerKey = try? session.read(account: "go")
            done.signal()
        }
        entered.wait()
        keychain.duringRead = nil
        try session.write("sk-new", account: "go")
        release.signal()
        done.wait()

        #expect(readerKey == "sk-new")
        #expect(try session.read(account: "go") == "sk-new")
        #expect(keychain.readCount("go") == 1)
    }
}

/// Stands in for the Keychain: counts reads per account and refuses with any status.
final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private var refusal: OSStatus?
    private var writeFailure: OSStatus?
    private var reads: [String: Int] = [:]
    private var hook: (@Sendable () -> Void)?

    init(_ values: [String: String] = [:]) { self.values = values }

    /// Runs inside each read after it is counted, where the real store would wait on a prompt.
    var duringRead: (@Sendable () -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    func refuse(with status: OSStatus?) { lock.withLock { refusal = status } }
    func failWrites(with status: OSStatus?) { lock.withLock { writeFailure = status } }
    func readCount(_ account: String) -> Int { lock.withLock { reads[account, default: 0] } }
    func value(_ account: String) -> String? { lock.withLock { values[account] } }

    /// Answers with what the store held when the read began, as a read that waited on a prompt would.
    func read(account: String) throws -> String? {
        let (value, refusal, hook) = lock.withLock {
            reads[account, default: 0] += 1
            return (values[account], self.refusal, self.hook)
        }
        hook?()
        if let refusal { throw SecretStoreError.keychain(refusal) }
        return value
    }

    func write(_ secret: String, account: String) throws {
        try lock.withLock {
            if let writeFailure { throw SecretStoreError.keychain(writeFailure) }
            values[account] = secret
        }
    }

    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
