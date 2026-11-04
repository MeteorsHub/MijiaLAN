import Foundation
import MijiaCore
import MijiaLAN

/// Private JSON-lines transport for the Matter sidecar. No TCP listener or device secrets in replies.
enum MatterRPC {
    struct Request: Decodable, Sendable {
        var id: Int
        var method: String
        var did: String?
        var on: Bool?
        var property: String?
        var value: JSONValue?
    }
    typealias Device = MatterDevicePlan.Device
    struct Reply: Encodable {
        var id: Int
        var devices: [Device]?
        var error: String?
    }

    static func devices(_ snapshots: [DeviceSnapshot]) -> [Device] { MatterDevicePlan.devices(snapshots) }

    @MainActor static func run(configURL: URL) async throws {
        guard let config = LocalHomeConfig.decode(try Data(contentsOf: configURL)) else {
            throw MiioError.badResponse("Invalid local-home configuration")
        }
        let api = LANMiotAPI(config: { config })
        let controller = DeviceController(api: api, config: { config })
        defer { controller.shutdown() }
        // readLine blocks, so keep it off the main actor used by DeviceController.
        while let line = await Task.detached(operation: { readLine() }).value {
            var requestID = 0
            let reply: Reply
            do {
                let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
                requestID = request.id
                switch request.method {
                case "snapshot":
                    await controller.refreshNow()
                case "set":
                    guard let did = request.did, let value = request.value ?? request.on.map(JSONValue.bool) else {
                        throw DeviceControlError.invalidValue("Matter request")
                    }
                    try await MatterDevicePlan.execute(controller: controller, endpoint: did,
                        property: request.property ?? "on", value: value)
                default:
                    throw DeviceControlError.unsupported("RPC method")
                }
                reply = Reply(id: request.id, devices: devices(Array(controller.snapshots.values)))
            } catch {
                // Validation/transport errors can carry diagnostic data; never echo arbitrary input or secrets.
                reply = Reply(id: requestID, error: "Device operation failed; check device availability and configuration.")
            }
            var data = try JSONEncoder().encode(reply)
            data.append(0x0a)
            try FileHandle.standardOutput.write(contentsOf: data)
        }
    }
}
