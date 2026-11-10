# hap-swift (vendored)

[acumen-dev/hap-swift](https://github.com/acumen-dev/hap-swift) at `638001bd3590082a8909fd4046ec226ab1349f20`, Apache 2.0 (`LICENSE.md`). Sources and manifest only; the upstream test targets are left out.

## Local changes

An encrypted HAP frame carries at most 1024 plaintext bytes (HAP spec §6.5.2). Upstream ignored that limit in both directions, which only shows once a bridge holds more than one small accessory:

- **Sending:** `HAPSession.encrypt` put a whole response into one frame. The `GET /accessories` answer of a bridge runs to several kilobytes; iOS drops the connection on the oversized frame and the Home app reports "Unable to Add Accessory". It now splits plaintext into frames of at most 1024 bytes.
- **Receiving:** `HAPConnectionContext` in `AppleTCPServer.swift` parsed each decrypted frame as a complete HTTP request and dropped a request spread over several frames without replying, such as iOS subscribing to every characteristic of a big bridge at once. It now keeps decrypted bytes until a whole request has arrived (`HTTPProtocol.requestLength(in:)`), then handles every complete request in them.

A third change is about Bonjour: upstream refreshed the TXT record after `POST /pairings` but not after pair-setup, so a freshly paired bridge kept advertising `sf=1` (unpaired). iOS looks the accessory up again to finish adding it and takes `sf=1` for a reset accessory. `CharacteristicProtocol.handlePairSetup` now re-advertises once pair-setup has stored the first controller.

`HAPLinux` keeps the upstream receive model with bounded HTTP input and invalid-framing rejection;
MijiaLAN only builds for macOS. It is not validated as a production Linux HAP server.

`HAPBridge.addAccessory` also accepts `appendingCharacteristicTypes`: these characteristics receive IIDs after
all existing services and characteristics. MijiaLAN uses this when adding Configured Name (`E3`) to an already
paired air conditioner's mode switches, preserving their service/On/Name IIDs and existing Home configuration.

`PairVerifyStateMachine` exposes the verified controller identifier after authentication. The Apple transport
passes it to characteristic handling so pairing administration can enforce controller permissions.

`PairingStateMachine` no longer includes session key prefixes in any log message. These were raw key bytes,
despite the upstream log text calling them a hash. MijiaLAN's app log handler also disables debug/trace dumps
by default and marks dynamic HAP log content private.

`CharacteristicProtocol.handleGetAccessories` checks the trace log level before converting its JSON response
body to a string, avoiding that extra allocation when body tracing is disabled.

Modified Swift files carry an explicit modification notice. `Package.swift` omits upstream test targets because
only sources are vendored; MijiaLAN maintains its own bridge and protocol regression tests.

## Security hardening

HTTP framing now rejects negative, overflowing, duplicate or excessive Content-Length values and Transfer-Encoding.
Headers are limited to 8 KiB and bodies to 56 KiB. The Apple transport limits connection buffers and connections,
expires unauthenticated and incomplete requests, closes invalid encrypted frames, and applies receive backpressure.
Incoming encrypted frames are limited to 1024 plaintext bytes.

Pairing stores persist administrator/user permission bytes. `/pairings` requires an authenticated administrator,
reports actual permissions, validates keys and rejects key replacement under an existing identifier.
Removing/demoting the last administrator revokes remaining users. Persistent updates are serialized and failed
vault saves leave live state unchanged. Legacy MijiaLAN blobs did not record roles and treated every controller
as an administrator; migration preserves that effective trust rather than inventing roles or resetting pairings.
New pairings always retain their declared roles. See `docs/security-hardening.md` in the MijiaLAN repository.

## Upstream MijiaLAN reliability integration

Integrated iPocket-APP/MijiaLAN's `35bc600`, `ab24c03`, `30a731c`, `a56d52f`, `d01c0f1` and `f3a41db` changes: numeric/string constraints, primary services, encrypted frame submission ordering, FIFO event delivery, mixed-read success statuses, response-before-event ordering and write-origin correction semantics. The regression suite includes authenticated TCP/UDP loopback and reference-value vectors.

This fork keeps its pairing permission checks, revoked-session validation, strict HTTP parser, 32-connection admission bound, bounded receive buffers and partial-request deadlines. A protocol failure closes the connection. The extra upstream raw HAP/miIO payload logging sink was not imported; the existing alias-only 64 MiB journal remains authoritative. Existing pairing storage and identifiers are retained.
