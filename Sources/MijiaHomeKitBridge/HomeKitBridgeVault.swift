import Foundation
import MijiaCore

/// The HomeKit bridge's secrets (identity key, setup code, paired controllers) as one opaque blob. The app decides
/// where it lives (the Keychain in `MijiaLANApp`, memory in tests).
public struct HomeKitBridgeVault: Sendable {
    public var load: @Sendable () -> CredentialVault.Lookup
    /// `nil` removes the blob. Returns false when the vault could not be written.
    public var save: @Sendable (Data?) -> Bool

    public init(load: @escaping @Sendable () -> CredentialVault.Lookup, save: @escaping @Sendable (Data?) -> Bool) {
        self.load = load
        self.save = save
    }
}
