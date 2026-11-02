// HTTPProtocol.swift
// Modified for MijiaLAN; see Vendor/hap-swift/README.md for the changes.
// Copyright 2026 Monagle Pty Ltd

import Foundation

// MARK: - HTTPRequest

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [(name: String, value: String)]
    public let body: Data

    public init(method: String, path: String, headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

// MARK: - HTTPResponse

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let statusMessage: String
    public let headers: [(name: String, value: String)]
    public let body: Data

    public init(statusCode: Int, statusMessage: String, headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.headers = headers
        self.body = body
    }
}

// MARK: - HTTPProtocol

public enum HTTPProtocol {

    // MARK: - Content Types

    public static let hapJSON = "application/hap+json"
    public static let pairingTLV8 = "application/pairing+tlv8"

    // MARK: - Parse Request

    /// Parses an HTTP/1.1 request from raw bytes.
    ///
    /// Headers are decoded as UTF-8 text (they must be ASCII per RFC 7230).
    /// The body is extracted as raw `Data` using the `Content-Length` header —
    /// this is essential for HAP pairing requests whose bodies are binary TLV8
    /// payloads that are NOT valid UTF-8. Converting them through a String would
    /// corrupt or silently drop bytes and cause iOS to time out waiting for M4/M6.
    public static func parseRequest(from data: Data) -> HTTPRequest? {
        // Locate the header/body boundary.
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let separatorRange = data.range(of: crlfcrlf) else { return nil }

        // Parse ONLY the header section as UTF-8 (body stays as raw Data).
        let headerSection = data[data.startIndex ..< separatorRange.lowerBound]
        guard let headerString = String(data: headerSection, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Request line: METHOD PATH HTTP/1.1
        let requestLine = lines[0].split(separator: " ", maxSplits: 2)
        guard requestLine.count >= 2 else { return nil }

        let method = String(requestLine[0])
        let path = String(requestLine[1])

        // Headers — collect and find Content-Length.
        var headers: [(name: String, value: String)] = []
        var contentLength: Int? = nil
        for i in 1 ..< lines.count {
            guard !lines[i].isEmpty else { break }
            if let colonIndex = lines[i].firstIndex(of: ":") {
                let name = String(lines[i][..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(lines[i][lines[i].index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers.append((name: name, value: value))
                if name.lowercased() == "content-length", let length = Int(value) {
                    contentLength = length
                }
            }
        }

        // Body: raw bytes immediately after the \r\n\r\n separator.
        let bodyStart = separatorRange.upperBound
        let availableBody = data[bodyStart...]

        let body: Data
        if let expectedLength = contentLength {
            // Require exactly Content-Length bytes — return nil if incomplete.
            guard availableBody.count >= expectedLength else { return nil }
            body = Data(availableBody.prefix(expectedLength))
        } else {
            body = Data(availableBody)
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    /// Byte length of the first complete request in `data` (headers plus `Content-Length` body bytes), or nil
    /// while more bytes are needed. Over an encrypted session a request larger than one HAP frame (1024 plaintext
    /// bytes) arrives in pieces; the caller keeps the decrypted bytes until this returns a length.
    public static func requestLength(in data: Data) -> Int? {
        let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let separatorRange = data.range(of: crlfcrlf) else { return nil }
        let headerLength = separatorRange.upperBound - data.startIndex
        var bodyLength = 0
        if let headerString = String(data: data[data.startIndex ..< separatorRange.lowerBound], encoding: .utf8) {
            for line in headerString.components(separatedBy: "\r\n").dropFirst() {
                guard let colonIndex = line.firstIndex(of: ":"),
                      line[..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else {
                    continue
                }
                bodyLength = max(0, Int(line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)) ?? 0)
            }
        }
        let total = headerLength + bodyLength
        return data.count >= total ? total : nil
    }

    // MARK: - Serialize Response

    public static func serializeResponse(_ response: HTTPResponse) -> Data {
        var result = "HTTP/1.1 \(response.statusCode) \(response.statusMessage)\r\n"

        var headers = response.headers
        // Add Content-Length if not present
        if !headers.contains(where: { $0.name.lowercased() == "content-length" }) {
            headers.append((name: "Content-Length", value: "\(response.body.count)"))
        }

        for header in headers {
            result += "\(header.name): \(header.value)\r\n"
        }
        result += "\r\n"

        var data = Data(result.utf8)
        data.append(response.body)
        return data
    }

    // MARK: - Convenience Builders

    public static func okResponse(body: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: [
                (name: "Content-Type", value: contentType),
            ],
            body: body
        )
    }

    public static func errorResponse(status: Int, message: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: status,
            statusMessage: message,
            headers: [],
            body: Data()
        )
    }

    public static func noContentResponse() -> HTTPResponse {
        HTTPResponse(statusCode: 204, statusMessage: "No Content")
    }
}
