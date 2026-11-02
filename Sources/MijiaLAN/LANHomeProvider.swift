import Foundation
import MijiaCore

/// The climate controls MijiaCore does not synthesize, located in a device's MIoT spec.
struct ClimateExtraKeys: Equatable, Sendable {
    var swing: MiotPropKey?
    /// The swing mode name while it is on: `vertical` or `horizontal`, after the property it writes.
    var swingAxis = "vertical"
    var power: MiotPropKey?

    var all: [MiotPropKey] { [swing, power].compactMap { $0 } }

    static func resolve(did: String, spec: MiotDeviceSpec) -> ClimateExtraKeys {
        var keys = ClimateExtraKeys()
        let controls = spec.services(named: "fan-control") + spec.services(named: "air-conditioner")
            + spec.services(named: "heater")
        for (name, axis) in [("vertical-swing", "vertical"), ("horizontal-swing", "horizontal")] {
            if let (service, property) = first(name, in: controls, writable: true) {
                keys.swing = MiotPropKey(did: did, siid: service.iid, piid: property.iid)
                keys.swingAxis = axis
                break
            }
        }
        let meters = spec.services(named: "power-consumption") + spec.services(named: "electricity")
        if let (service, property) = first("electric-power", in: meters, writable: false) {
            keys.power = MiotPropKey(did: did, siid: service.iid, piid: property.iid)
        }
        return keys
    }

    private static func first(_ name: String, in services: [MiotService], writable: Bool) -> (MiotService, MiotProperty)? {
        for service in services {
            if let property = service.properties.first(where: { $0.shortName == name && $0.isReadable && (!writable || $0.isWritable) }) {
                return (service, property)
            }
        }
        return nil
    }
}

/// `MiCloudProvider` plus what MijiaCore leaves out for a climate device: the swing flap, merged into
/// `ClimateSpec.swingMode` and written for `setClimateSwingMode`, and the power draw, published for the panel.
/// Both are read as companions of the device's regular poll.
public actor LANHomeProvider: HomeProvider {
    private let inner: MiCloudProvider
    private let api: LANMiotAPI
    private let specSource: any MiotSpecSource
    private var extras: [String: (model: String, keys: ClimateExtraKeys)] = [:]
    private var powerObserver: (@Sendable ([String: Double]) -> Void)?

    init(inner: MiCloudProvider, api: LANMiotAPI, specSource: any MiotSpecSource) {
        self.inner = inner
        self.api = api
        self.specSource = specSource
    }

    /// Watts by device ID, after every snapshot.
    public func observePower(_ observer: @escaping @Sendable ([String: Double]) -> Void) {
        powerObserver = observer
    }

    public nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        let upstream = inner.events()
        return AsyncStream { continuation in
            let task = Task {
                for await event in upstream {
                    if case .snapshotUpdated(let home) = event {
                        continuation.yield(.snapshotUpdated(await self.enrich(home)))
                    } else {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func execute(_ command: DeviceCommand) async throws {
        guard case .setClimateSwingMode(let entityId, let swingMode) = command else {
            return try await inner.execute(command)
        }
        guard let did = MiotAddress.parse(entityId)?.did, let key = extras[did]?.keys.swing else {
            throw MiotCommandError.unsupported("setClimateSwingMode")
        }
        try await api.setProps([MiotPropWrite(did: did, siid: key.siid, piid: key.piid, value: .bool(swingMode != "off"))])
    }

    public func refreshNow() async { await inner.refreshNow() }

    public func setPollingContext(_ context: PollingContext) async { await inner.setPollingContext(context) }

    public func fetchSensorHistory(deviceId: String, window: SensorHistoryWindow, now: Date) async -> [SensorHistorySample] {
        await inner.fetchSensorHistory(deviceId: deviceId, window: window, now: now)
    }

    public func shutdown() async { await inner.shutdown() }

    // MARK: Climate Extras

    func enrich(_ home: SynthesizedHome) async -> SynthesizedHome {
        var home = home
        var power: [String: Double] = [:]
        let devices = Dictionary(api.config().devices.map { ($0.did, $0) }, uniquingKeysWith: { first, _ in first })
        for index in home.devices.indices {
            guard case .climate(var spec) = home.devices[index].kind,
                  let did = MiotAddress.parse(spec.entityId)?.did, let device = devices[did],
                  let keys = await extraKeys(for: device) else { continue }
            if let key = keys.swing, let value = await api.latestValue(key), let on = value.boolValue ?? value.doubleValue.map({ $0 != 0 }) {
                spec.swingMode = on ? keys.swingAxis : "off"
                spec.availableSwingModes = ["off", keys.swingAxis]
                home.devices[index].kind = .climate(spec)
            }
            if let key = keys.power, let watts = await api.latestValue(key)?.doubleValue {
                power[did] = watts
            }
        }
        powerObserver?(power)
        return home
    }

    /// Resolved once per device and model; registered with the API so the next poll reads them.
    private func extraKeys(for device: LocalDevice) async -> ClimateExtraKeys? {
        if let cached = extras[device.did], cached.model == device.model { return cached.keys }
        // A spec that fails to load now is tried again with the next snapshot.
        guard let spec = try? await specSource.spec(model: device.model, specType: device.specType) else { return nil }
        let keys = ClimateExtraKeys.resolve(did: device.did, spec: spec)
        extras[device.did] = (device.model, keys)
        await api.setCompanions(keys.all, for: device.did)
        return keys
    }
}
