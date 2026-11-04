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
    public static let maxHeaderBytes = 8 * 1024
    public static let maxBodyBytes = 56 * 1024
    public static let maxRequestBytes = maxHeaderBytes + maxBodyBytes

    public enum RequestBoundary: Equatable, Sendable {
        case incomplete, invalid
        case complete(Int)
    }

    /// Validate framing before allocating or slicing. HAP does not use chunked requests.
    public static func requestBoundary(in data: Data) -> RequestBoundary {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .invalid : .incomplete
        }
        let headerLength = data.distance(from: data.startIndex, to: range.upperBound)
        guard headerLength <= maxHeaderBytes,
              let header = String(data: data[..<range.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" else { return .invalid }
        var bodyLength: Int?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" { return .invalid }
            if name == "content-length" {
                guard bodyLength == nil, !value.isEmpty,
                      value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let length = Int(value), length <= maxBodyBytes else { return .invalid }
                bodyLength = length
            }
        }
        // Both operands are bounded, so hostile lengths cannot overflow this addition.
        let total = headerLength + (bodyLength ?? 0)
        return data.count >= total ? .complete(total) : .incomplete
    }

    public static func parseRequest(from data: Data) -> HTTPRequest? {
        guard case .complete(let length) = requestBoundary(in: data),
              let separator = data.range(of: Data([13, 10, 13, 10])),
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        let headers = lines.dropFirst().compactMap { line -> (name: String, value: String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        let end = data.index(data.startIndex, offsetBy: length)
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers,
                           body: Data(data[separator.upperBound..<end]))
    }

    public static func requestLength(in data: Data) -> Int? {
        guard case .complete(let length) = requestBoundary(in: data) else { return nil }
        return length
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
