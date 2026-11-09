import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A bounded streaming JSONL decoder; captured file size excludes rows appended during an export.
final class DeviceLogHistoryReader {
    static let maximumLineBytes = 16_384
    let length: UInt64
    private let file: FileHandle
    private var remaining: UInt64
    private var buffer = Data()
    private var discarding = false
    private let decoder: JSONDecoder

    init(_ url: URL, limit: Int) throws {
        // Read actual filesystem metadata, never URL's cached resource values.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let length = (attributes[.size] as? NSNumber)?.uint64Value, length <= UInt64(limit) else { throw CocoaError(.fileReadTooLarge) }
        self.length = length; remaining = length
        file = try FileHandle(forReadingFrom: url)
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }
    deinit { try? file.close() }

    func next() throws -> DeviceEventLog.Event? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                if discarding { discarding = false; continue }
                if line.count <= Self.maximumLineBytes, let event = try? decoder.decode(DeviceEventLog.Event.self, from: line) { return event }
                continue
            }
            if buffer.count > Self.maximumLineBytes { buffer.removeAll(keepingCapacity: true); discarding = true }
            guard remaining > 0 else { return nil } // A partial final row was never a committed event.
            let bytes = try file.read(upToCount: Int(min(65_536, remaining))) ?? Data()
            guard !bytes.isEmpty else { remaining = 0; return nil }
            remaining -= UInt64(bytes.count); buffer.append(bytes)
        }
    }
    static func replace(_ temporary: URL, _ destination: URL) throws {
        let result = temporary.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in rename(source!, target!) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
