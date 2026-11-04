import Foundation
import HAPCrypto

/// The bridge's long-term identity and its paired controllers, stored as one blob in `HomeKitBridgeVault`.
///
/// Losing it means Apple Home sees a new, unpaired bridge, so it is written before the bridge goes online and
/// whenever a controller pairs or unpairs.
struct HomeKitBridgeSecrets: Codable, Equatable, Sendable {
    /// HAP device ID, `AA:BB:CC:DD:EE:FF`. Apple Home keys the pairing on it.
    var deviceID: String
    /// `XXX-XX-XXX`, typed or scanned once in the Home app.
    var setupCode: String
    /// Four characters hashed into the mDNS `sh` record so a scanned QR code finds this bridge.
    var setupID: String
    /// Ed25519 long-term signing key (32 raw bytes).
    var signingKey: Data
    /// Controller pairing ID → its Ed25519 public key.
    var pairings: [String: Data]
    /// Nil denotes a legacy store, whose controllers were all administrators.
    var pairingPermissions: [String: UInt8]? = nil

    static func generate() -> HomeKitBridgeSecrets {
        var generator = SystemRandomNumberGenerator()
        return HomeKitBridgeSecrets(
            deviceID: HomeKitSetupCode.makeDeviceID(using: &generator),
            setupCode: HomeKitSetupCode.generate(using: &generator),
            setupID: HomeKitSetupCode.makeSetupID(using: &generator),
            signingKey: HAPIdentity().privateKeyData,
            pairings: [:]
        )
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> HomeKitBridgeSecrets? {
        guard let secrets = try? JSONDecoder().decode(HomeKitBridgeSecrets.self, from: data),
              secrets.signingKey.count == 32,
              HomeKitSetupCode.isValid(secrets.setupCode) else { return nil }
        return secrets
    }
}

/// Setup codes, setup IDs, device IDs and the `X-HM://` URI behind the pairing QR code.
public enum HomeKitSetupCode {
    /// Codes the HAP specification forbids because they are trivial to guess.
    static let forbidden: Set<String> = Set((0...9).map { d in
        let s = String(d)
        return "\(s)\(s)\(s)-\(s)\(s)-\(s)\(s)\(s)"
    }).union(["123-45-678", "876-54-321"])

    public static func isValid(_ code: String) -> Bool {
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [3, 2, 3], code.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }) else {
            return false
        }
        return !forbidden.contains(code)
    }

    static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
        while true {
            let digits = (0..<8).map { _ in String(Int.random(in: 0...9, using: &generator)) }.joined()
            let code = "\(digits.prefix(3))-\(digits.dropFirst(3).prefix(2))-\(digits.suffix(3))"
            if isValid(code) { return code }
        }
    }

    static func makeSetupID<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String((0..<4).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    static func makeDeviceID<G: RandomNumberGenerator>(using generator: inout G) -> String {
        (0..<6).map { _ in String(format: "%02X", UInt8.random(in: 0...255, using: &generator)) }
            .joined(separator: ":")
    }

    /// The payload Apple Home scans (HAP 5.10.3): `category << 31 | IP flag << 27 | code`, base36 in nine
    /// characters, then the setup ID. Category 2 is a bridge.
    public static func setupURI(setupCode: String, setupID: String, category: UInt64 = 2) -> String? {
        let digits = setupCode.filter(\.isNumber)
        guard digits.count == 8,
              setupCode.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "-") }),
              setupID.count == 4,
              let code = UInt64(digits) else { return nil }
        let ipTransport: UInt64 = 2
        let payload = category << 31 | ipTransport << 27 | code
        return "X-HM://" + base36(payload, width: 9) + setupID
    }

    private static func base36(_ value: UInt64, width: Int) -> String {
        let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var value = value
        var result = ""
        repeat {
            result = String(digits[Int(value % 36)]) + result
            value /= 36
        } while value > 0
        return String(repeating: "0", count: max(0, width - result.count)) + result
    }
}

/// Pairings live in memory and are written through `persist` on every change; a failed write fails the pairing
/// step, so Apple Home never holds a pairing the bridge forgets on restart.
actor HomeKitBridgePairingStore: PairingStore {
    enum PersistError: Error {
        case vaultUnavailable
    }

    private var pairings: [String: Data]
    private var roles: [String: UInt8]
    private var writing = false
    private var writers: [CheckedContinuation<Void, Never>] = []
    private let persist: @Sendable ([String: Data], [String: UInt8]) async -> Bool
    private let onChange: @Sendable (Bool) async -> Void

    init(
        pairings: [String: Data],
        permissions: [String: UInt8]? = nil,
        persist: @escaping @Sendable ([String: Data], [String: UInt8]) async -> Bool,
        onChange: @escaping @Sendable (_ isPaired: Bool) async -> Void = { _ in }
    ) {
        self.pairings = pairings
        self.roles = pairings.mapValues { _ in UInt8(1) }
        if let permissions {
            self.roles = pairings.mapValues { _ in UInt8(0) }
                .merging(permissions.filter { pairings[$0.key] != nil }) { _, role in role == 1 ? 1 : 0 }
        }
        self.persist = persist
        self.onChange = onChange
    }

    func store(controllerIdentifier: String, publicKey: Data, permissions: UInt8) async throws {
        await acquireWrite()
        defer { releaseWrite() }
        var next = pairings
        var nextRoles = roles
        next[controllerIdentifier] = publicKey
        nextRoles[controllerIdentifier] = permissions == 1 ? 1 : 0
        try await commit(next, roles: nextRoles)
    }

    func store(controllerIdentifier: String, publicKey: Data) async throws {
        try await store(controllerIdentifier: controllerIdentifier, publicKey: publicKey, permissions: 1)
    }

    func permissions(for controllerIdentifier: String) -> UInt8? { roles[controllerIdentifier] }

    func publicKey(for controllerIdentifier: String) -> Data? {
        pairings[controllerIdentifier]
    }

    func remove(controllerIdentifier: String) async throws {
        await acquireWrite()
        defer { releaseWrite() }
        guard pairings[controllerIdentifier] != nil else { return }
        var next = pairings
        next.removeValue(forKey: controllerIdentifier)
        var nextRoles = roles
        nextRoles.removeValue(forKey: controllerIdentifier)
        try await commit(next, roles: nextRoles)
    }

    func listPairings() -> [(identifier: String, publicKey: Data, permissions: UInt8)] {
        pairings.map { (identifier: $0.key, publicKey: $0.value, permissions: roles[$0.key] ?? 0) }
    }

    var isPaired: Bool {
        !pairings.isEmpty
    }

    private func acquireWrite() async {
        if !writing { writing = true; return }
        await withCheckedContinuation { writers.append($0) }
    }

    private func releaseWrite() {
        if writers.isEmpty { writing = false } else { writers.removeFirst().resume() }
    }

    private func commit(_ proposed: [String: Data], roles proposedRoles: [String: UInt8]) async throws {
        let hasAdmin = proposedRoles.values.contains(1)
        let next = hasAdmin ? proposed : [:]
        let nextRoles = hasAdmin ? proposedRoles : [:]
        guard await persist(next, nextRoles) else { throw PersistError.vaultUnavailable }
        pairings = next
        roles = nextRoles
        await onChange(!next.isEmpty)
    }
}
