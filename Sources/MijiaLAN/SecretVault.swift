import Foundation
import MijiaCore
import Security

/// Every secret (device tokens, the HomeKit bridge identity) in **one** Keychain item, read once per process.
///
/// The app is ad-hoc signed, so macOS asks again after every rebuild; one item means one prompt instead of one per
/// secret. An item that cannot be read reads as `.unavailable` and is never overwritten, so a declined prompt cannot
/// wipe the other secrets.
public final class SecretVault: @unchecked Sendable {
    public struct Storage: Sendable {
        public enum ReadResult: Equatable, Sendable {
            case found(Data)
            case notFound
            case unavailable
        }

        public var read: @Sendable () -> ReadResult
        public var write: @Sendable (Data) -> Bool

        public init(read: @escaping @Sendable () -> ReadResult, write: @escaping @Sendable (Data) -> Bool) {
            self.read = read
            self.write = write
        }

        public static func keychain(service: String, account: String) -> Storage {
            Storage(
                read: { KeychainItem.read(service: service, account: account) },
                write: { KeychainItem.write($0, service: service, account: account) }
            )
        }

        /// Tests.
        public static func memory() -> Storage {
            let box = MemoryBox()
            return Storage(read: { box.read() }, write: { box.write($0) })
        }
    }

    private enum State {
        case unloaded
        case loaded([String: Data])
        case unavailable
    }

    private let storage: Storage
    private let lock = NSLock()
    private var state = State.unloaded

    public init(storage: Storage) {
        self.storage = storage
    }

    public func lookup(_ account: String) -> CredentialVault.Lookup {
        lock.lock()
        defer { lock.unlock() }
        switch load() {
        case .loaded(let items): return items[account].map(CredentialVault.Lookup.value) ?? .missing
        case .unavailable, .unloaded: return .unavailable
        }
    }

    /// `nil` removes the entry. Returns false (and changes nothing) when the item could not be read or written.
    @discardableResult
    public func set(_ data: Data?, for account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .loaded(var items) = load() else { return false }
        items[account] = data
        guard let encoded = try? JSONEncoder().encode(items), storage.write(encoded) else { return false }
        state = .loaded(items)
        return true
    }

    private func load() -> State {
        if case .unloaded = state {
            switch storage.read() {
            case .found(let data):
                state = (try? JSONDecoder().decode([String: Data].self, from: data)).map(State.loaded) ?? .unavailable
            case .notFound:
                state = .loaded([:])
            case .unavailable:
                // Retried on the next access: the user may have declined by accident.
                return .unavailable
            }
        }
        return state
    }
}

private final class MemoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func read() -> SecretVault.Storage.ReadResult {
        lock.lock()
        defer { lock.unlock() }
        return data.map(SecretVault.Storage.ReadResult.found) ?? .notFound
    }

    func write(_ next: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        data = next
        return true
    }
}

enum KeychainItem {
    static func read(service: String, account: String) -> SecretVault.Storage.ReadResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return (result as? Data).map(SecretVault.Storage.ReadResult.found) ?? .unavailable
        case errSecItemNotFound: return .notFound
        default: return .unavailable
        }
    }

    static func write(_ data: Data, service: String, account: String) -> Bool {
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update = SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = match
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel] = "MijiaLAN（米家局域网 token 与 HomeKit 配对）"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
