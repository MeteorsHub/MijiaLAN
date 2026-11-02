# hap-swift (vendored)

[acumen-dev/hap-swift](https://github.com/acumen-dev/hap-swift) at `638001bd3590082a8909fd4046ec226ab1349f20`, Apache 2.0 (`LICENSE.md`). Sources and manifest only; the upstream test targets are left out.

## Local changes

An encrypted HAP frame carries at most 1024 plaintext bytes (HAP spec §6.5.2). Upstream ignored that limit in both directions, which only shows once a bridge holds more than one small accessory:

- **Sending:** `HAPSession.encrypt` put a whole response into one frame. The `GET /accessories` answer of a bridge runs to several kilobytes; iOS drops the connection on the oversized frame and the Home app reports "Unable to Add Accessory". It now splits plaintext into frames of at most 1024 bytes.
- **Receiving:** `HAPConnectionContext` in `AppleTCPServer.swift` parsed each decrypted frame as a complete HTTP request and dropped a request spread over several frames without replying, such as iOS subscribing to every characteristic of a big bridge at once. It now keeps decrypted bytes until a whole request has arrived (`HTTPProtocol.requestLength(in:)`), then handles every complete request in them.

A third change is about Bonjour: upstream refreshed the TXT record after `POST /pairings` but not after pair-setup, so a freshly paired bridge kept advertising `sf=1` (unpaired). iOS looks the accessory up again to finish adding it and takes `sf=1` for a reset accessory. `CharacteristicProtocol.handlePairSetup` now re-advertises once pair-setup has stored the first controller.

`HAPLinux` keeps the upstream receive path; MijiaLAN only builds for macOS.

`HAPBridge.addAccessory` also accepts `appendingCharacteristicTypes`: these characteristics receive IIDs after
all existing services and characteristics. MijiaLAN uses this when adding Configured Name (`E3`) to an already
paired air conditioner's mode switches, preserving their service/On/Name IIDs and existing Home configuration.

`PairVerifyStateMachine` exposes the verified controller identifier after authentication. The Apple transport
passes it to characteristic handling so pairing administration can enforce controller permissions.

`PairingStateMachine` no longer includes session key prefixes in any log message. These were raw key bytes,
despite the upstream log text calling them a hash. MijiaLAN's app log handler also disables debug/trace dumps
by default and marks dynamic HAP log content private.

Modified Swift files carry an explicit modification notice. `Package.swift` omits upstream test targets because
only sources are vendored; MijiaLAN maintains its own bridge and protocol regression tests.
