import Foundation
import MijiaCore

/// The app and CLI share MijiaCore's thread-safe, two-language vocabulary.
/// Resolve once before building device snapshots or HomeKit display names.
public enum LANLocalization {
    public static func language(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let primary = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            if primary == "zh" { return .zhHans }
            if primary == "en" { return .en }
        }
        return .en
    }

    @discardableResult
    public static func configure(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        let language = language(preferredLanguages: preferredLanguages)
        L10n.currentLanguage = language
        return language
    }
}
