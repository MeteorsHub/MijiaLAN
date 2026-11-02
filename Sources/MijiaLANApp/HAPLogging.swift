import Logging
import os

/// hap-swift logs through swift-log, which prints to stdout and is lost when the app is opened from Finder. This
/// sends it to the unified log instead, where a failed pairing can be read afterwards:
///
///     log show --last 1h --predicate 'subsystem == "com.mijialan.MijiaLAN" AND category BEGINSWITH "hap."'
///
/// Keep verbose request/accessory dumps disabled by default. Upstream messages can contain controller identifiers,
/// device names and readings, so all dynamic message text remains private in the unified log.
struct UnifiedLogHandler: LogHandler {
    var logLevel: Logging.Logger.Level
    var metadata: Logging.Logger.Metadata = [:]
    private let logger: os.Logger

    init(label: String) {
        logger = os.Logger(subsystem: "com.mijialan.MijiaLAN", category: label)
        logLevel = .info
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        for text in Self.pieces(of: event.message.description) {
            switch event.level {
            case .trace, .debug:
                logger.debug("\(text, privacy: .private)")
            case .info:
                logger.info("\(text, privacy: .private)")
            case .notice:
                logger.notice("\(text, privacy: .private)")
            case .warning, .error, .critical:
                logger.error("\(text, privacy: .private)")
            }
        }
    }

    /// The log store cuts long messages short, and the accessory list runs to several kilobytes: longer messages
    /// go out as numbered pieces.
    static func pieces(of text: String, maxBytes: Int = 800) -> [String] {
        guard text.utf8.count > maxBytes else { return [text] }
        var pieces: [String] = []
        var current = ""
        var bytes = 0
        for character in text {
            let size = character.utf8.count
            if bytes + size > maxBytes {
                pieces.append(current)
                current = ""
                bytes = 0
            }
            current.append(character)
            bytes += size
        }
        pieces.append(current)
        return pieces.enumerated().map { "[\($0.offset + 1)/\(pieces.count)] \($0.element)" }
    }
}
