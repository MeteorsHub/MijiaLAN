import Foundation

/// Local logical addresses from the pinned hass-xiaomi-miot extension, never native MIoT wire addresses.
enum YeelightCeiling20Schema {
    static func extending(_ original: DeviceSchema, model: String) -> DeviceSchema {
        guard model == "yeelink.light.ceiling20", original.category == "light",
              let main = original.services.first(where: { $0.iid == 2 && $0.name == "light" }),
              main.properties.contains(where: { $0.iid == 1 && $0.name == "on" && $0.format == "bool" }),
              main.properties.contains(where: { $0.iid == 2 && $0.name == "brightness" }) else { return original }
        // Do not overwrite any real service already supplied by a newer imported specification.
        guard !original.services.contains(where: { $0.iid == 200 }) else { return original }
        guard let extra = try? JSONDecoder().decode(DeviceSchema.Service.self, from: Data(ambient.utf8)) else { return original }
        var result = original
        result.services.append(extra)
        return result
    }

    // al-one/hass-xiaomi-miot@75bc74f: miot_specs_extend.json ceiling20 -> ceiling4.
    private static let ambient = #"""
    {"iid":200,"type":"urn:miot-spec-v2:service:ambient-light","description":"Ambient Light","properties":[
      {"iid":201,"type":"urn:miot-spec-v2:property:on","format":"bool","access":["read","write"]},
      {"iid":202,"type":"urn:miot-spec-v2:property:brightness","format":"uint8","access":["read","write"],"unit":"percentage","value-range":[1,100,1]},
      {"iid":203,"type":"urn:miot-spec-v2:property:color-temperature","format":"uint32","access":["read","write"],"unit":"kelvin","value-range":[1700,6500,1]},
      {"iid":204,"type":"urn:miot-spec-v2:property:color","format":"uint32","access":["read","write"],"unit":"rgb","value-range":[1,16777215,1]}
    ]}
    """#
}
