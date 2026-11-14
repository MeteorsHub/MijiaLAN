# homebridge-miot (ported rules)

[merdok/homebridge-miot](https://github.com/merdok/homebridge-miot) at `2186f61f2081ec1a51c0388e3072b79741aebb0a`, MIT (`LICENSE`). No source code is vendored.

## What is used

`CapabilityHomeKitMapper.native` in `Sources/MijiaHomeKitBridge` follows the main services of homebridge-miot's category accessories (`lib/modules/<category>/*Accessory.js`): which MIoT properties become which Apple Home characteristics, and how states and modes are derived.

| Category | Home service | Properties |
| --- | --- | --- |
| humidifier, dehumidifier | Humidifier Dehumidifier | on, relative humidity, target humidity, water level |
| heater | Heater Cooler, heat only | on, target temperature, temperature |
| air-conditioner | Heater Cooler | on, mode (auto / heat / cool), target temperature, temperature, swing |
| curtain | Window Covering | current and target position, status |
| vacuum | Switch | status; actions start-sweep (on) and battery start-charge (off) |

## Changes

- Rewritten in Swift on top of MijiaLAN's capability catalog; values are only read from and written to properties the spec declares.
- A category keeps an outlet and named switches when a property the service requires is missing, instead of reporting a default value.
- Fan levels stay named switches rather than a rotation speed, since their values carry no speed scale.
- A vacuum's switch reads on from the status descriptions, as `isVacuumWorking` does, and also confirms each action from them. The dock occupancy sensor and room cleaning are left out.
- Extra controls such as child lock, buzzer and indicator light remain the named switches MijiaLAN already generates, rather than opt-in settings.
- The 10 built-in models keep their existing mapping.
