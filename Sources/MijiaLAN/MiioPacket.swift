import CommonCrypto
import CryptoKit
import Foundation

/// miIO LAN framing (UDP 54321): a 32-byte header followed by the AES-128-CBC encrypted JSON command.
///
///     0       2       4           8           12          16                    32
///     | 2131  | len   | unknown   | device ID | stamp     | checksum (MD5)      | payload…
///
/// Key = MD5(token), IV = MD5(key ‖ token). The checksum is MD5 over header bytes 0..<16, the token and the encrypted
/// payload. A hello is a bare header filled with 0xFF; the reply carries the device ID and the device's clock.
public enum MiioPacket {
    public static let port: UInt16 = 54321
    public static let headerLength = 32
    static let magic: [UInt8] = [0x21, 0x31]

    public static let hello = Data(magic + [0x00, 0x20] + [UInt8](repeating: 0xFF, count: 28))

    public struct Header: Equatable, Sendable {
        public var length: Int
        public var deviceID: UInt32
        public var stamp: UInt32
        /// Header bytes 16..<32: the checksum, or in a hello reply the token (unprovisioned devices only), else
        /// all 0x00 or all 0xFF.
        public var checksum: Data

        /// The token a hello reply reveals; modern firmware never does.
        public var revealedToken: String? {
            let bytes = [UInt8](checksum)
            guard bytes.count == 16, !bytes.allSatisfy({ $0 == 0x00 }), !bytes.allSatisfy({ $0 == 0xFF }) else { return nil }
            return MiioToken.hex(Data(bytes))
        }
    }

    public static func parseHeader(_ packet: Data) throws -> Header {
        let bytes = [UInt8](packet)
        guard bytes.count >= headerLength, Array(bytes[0..<2]) == magic else { throw MiioError.malformedPacket }
        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        guard length >= headerLength, length <= bytes.count else { throw MiioError.malformedPacket }
        return Header(
            length: length,
            deviceID: readUInt32(bytes, at: 8),
            stamp: readUInt32(bytes, at: 12),
            checksum: Data(bytes[16..<32])
        )
    }

    public static func encode(_ payload: Data, token: Data, deviceID: UInt32, stamp: UInt32) throws -> Data {
        let encrypted = try MiioCipher(token: token).encrypt(payload)
        let length = headerLength + encrypted.count
        guard length <= Int(UInt16.max) else { throw MiioError.malformedPacket }
        var header = magic + [UInt8(length >> 8), UInt8(length & 0xFF), 0, 0, 0, 0]
        header += bigEndianBytes(deviceID) + bigEndianBytes(stamp)
        let checksum = Insecure.MD5.hash(data: Data(header) + token + encrypted)
        return Data(header) + Data(checksum) + encrypted
    }

    /// Verifies the checksum and decrypts. A checksum mismatch almost always means the token is wrong.
    public static func decode(_ packet: Data, token: Data) throws -> (header: Header, payload: Data) {
        let header = try parseHeader(packet)
        let bytes = [UInt8](packet)
        let encrypted = Data(bytes[headerLength..<header.length])
        guard !encrypted.isEmpty else { return (header, Data()) }
        let expected = Data(Insecure.MD5.hash(data: Data(bytes[0..<16]) + token + encrypted))
        guard expected == header.checksum else { throw MiioError.checksumMismatch }
        return (header, try MiioCipher(token: token).decrypt(encrypted))
    }

    static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

/// AES-128-CBC with PKCS#7 padding, keyed from the device token.
struct MiioCipher {
    let key: Data
    let iv: Data

    init(token: Data) throws {
        guard token.count == 16 else { throw MiioError.invalidToken }
        key = Data(Insecure.MD5.hash(data: token))
        iv = Data(Insecure.MD5.hash(data: key + token))
    }

    func encrypt(_ data: Data) throws -> Data { try crypt(data, operation: CCOperation(kCCEncrypt)) }
    func decrypt(_ data: Data) throws -> Data { try crypt(data, operation: CCOperation(kCCDecrypt)) }

    private func crypt(_ input: Data, operation: CCOperation) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(
                            operation, CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, v.baseAddress,
                            inp.baseAddress, input.count,
                            out.baseAddress, capacity, &written
                        )
                    }
                }
            }
        }
        // A decrypt failure is a wrong token that happened to pass no checksum (hello replies) or a corrupt packet.
        guard status == CCCryptorStatus(kCCSuccess) else { throw MiioError.checksumMismatch }
        return output.prefix(written)
    }
}

public enum MiioToken {
    /// 32 hex characters, as the cloud and the Mi Home app show it. Whitespace is ignored.
    public static func parse(_ text: String) -> Data? {
        let hex = text.filter { !$0.isWhitespace }
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    public static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    public static func isValid(_ text: String) -> Bool { parse(text) != nil }
}

public enum MiioError: LocalizedError, Equatable, Sendable {
    case malformedPacket
    /// The reply did not verify with the token: the token is wrong or the device was re-paired.
    case checksumMismatch
    case invalidToken
    case timeout
    /// The device answered the hello but none of the encrypted requests: almost always a wrong token.
    case noEncryptedReply
    /// Nothing answers ARP at that IP (`EHOSTUNREACH` / `EHOSTDOWN`).
    case hostUnreachable
    /// A pre-MIoT device whose legacy table has no counterpart for this write or action.
    case unsupportedByLegacyDevice
    case socket(String)
    case badResponse(String)
    /// The device answered with `{"error": {...}}`.
    case deviceError(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .malformedPacket: return "收到的数据包格式不对"
        case .checksumMismatch: return "token 不匹配（设备可能已重新配网，需要重新导入）"
        case .invalidToken: return "token 应为 32 位十六进制"
        case .timeout: return "设备没有响应（离线、IP 变了，或不在同一局域网）"
        case .noEncryptedReply: return "设备回应了握手，但不回应加密指令：token 多半不对或已变（重新配网后会变）"
        case .hostUnreachable: return "这个 IP 上没有设备：可能断电、离线或换了 IP（也可能 App 没有「本地网络」权限）"
        case .unsupportedByLegacyDevice: return "这款老设备在局域网里不支持这个操作"
        case .socket(let message): return "网络错误：\(message)"
        case .badResponse(let what): return "设备响应异常：\(what)"
        case .deviceError(let code, let message): return "设备返回错误 \(code)：\(message)"
        }
    }
}
