# MijiaLAN

[简体中文](README.md) · **English**

Control Mijia Wi-Fi devices from your Mac menu bar and bring them into Apple Home.

MijiaLAN talks directly to devices over your local network using miIO / MIoT. Add a device with an existing token, or scan a QR code with Xiaomi Home to import credentials from Xiaomi once. Daily control then uses the LAN. Your Mac also acts as a HomeKit bridge for iPhone, Apple Watch, HomePod and Siri.

> `dooya.motor.dc1545` preferences persist without startup or idle requests. Explicit position/Open/Close/Stop operations retain preflight validation and bounded readback. Settings provides private, rolling logs for all App-managed LAN device communication. See [silent mode and diagnostics](docs/device-diagnostics-and-curtain-silence.md).

## Features

- **Control Center style panel** with device tiles, power controls, detail pages and offline explanations. Left-click to show or hide the panel; right-click for the Quit menu.
- **Apple Home bridge** with lights, outlets, fans, air purifiers, air conditioners and sensors. Choose which devices to expose.
- **Detailed controls and shared state**: the Mac and HomeKit share capabilities, polling and command execution for supported modes, brightness, color temperature, temperature, fan speed, swing, readings and cooking presets.
- **Local credentials**: device tokens, the registry and HomeKit pairing material live in macOS Keychain. Xiaomi cloud login sessions are not persisted.
- **Chinese and English UI**, with system, light and dark appearances.
- **IP rediscovery** to recover from DHCP address changes using device IDs.
- **Background performance**: offline retries back off to a maximum interval of 24 hours. The panel releases its views after 30 seconds hidden while retaining the page, scroll position and input drafts. See [performance and background operation](docs/performance.md).

## Requirements

- macOS 15 or later.
- An Apple Silicon or Intel Mac. Release packages include both architectures.
- Connectivity between your Mac and devices, with Local Network permission enabled. HomeKit discovery also needs reachable Bonjour / mDNS.
- Internet access for QR import and uncached device specifications.

## Download and install

Download `MijiaLAN-<version>-universal.dmg` from [GitHub Releases](https://github.com/iPocket-APP/MijiaLAN/releases/latest), open it and drag `MijiaLAN.app` into Applications, then launch it. A ZIP package and `SHA256SUMS.txt` checksums are also available.

Release packages are Developer ID signed with Hardened Runtime enabled and notarized by Apple. Both the app and disk image have stapled notarization tickets. Allow Local Network access when prompted.

## Build and launch

Source builds require Xcode / command line tools providing **Swift 6.4 or later** and internet access for the initial SwiftPM dependency download.

```bash
git clone https://github.com/iPocket-APP/MijiaLAN.git
cd MijiaLAN
./scripts/build_app.sh
open build/MijiaLAN.app
```

By default, the script produces an ad hoc signed `build/MijiaLAN.app` for local use. Source builds are not automatically notarized. See the [release workflow](docs/releasing.md) for distribution packaging.

## Setup

1. Open the menu bar panel and enter Settings.
2. Select your server region, start QR import and confirm with Xiaomi Home. Alternatively, enter the device IP and its 32 character hexadecimal token manually.
3. Choose the devices to expose in HomeKit settings. Exclude devices already connected to HomeKit natively to avoid duplicates.
4. In Apple Home on iPhone, select **+ → Add Accessory** and scan the bridge QR code. Confirm the uncertified accessory prompt to continue.

Keep the Mac and app running. Idle sleep prevention is enabled by default and can be disabled in Settings. Devices may become unresponsive in Apple Home while the Mac sleeps, shuts down or the app exits. Remote access and home automations also require a home hub such as HomePod or Apple TV.

Reconfiguring a device's Wi-Fi may change its token; import it again in that case. A device needs valid credentials, an IP address and firmware that supports LAN control.

## Device support and limitations

The app bundles specifications and capability mappings for these **10 models**. Specifications, protocol mappings and automated tests do not establish hardware acceptance for every feature or firmware version.

| Category | Models |
| --- | --- |
| Outlets | `chuangmi.plug.m3`, `cuco.plug.v3` |
| Air purifier | `zhimi.airpurifier.rma1` |
| Desk lamp | `yeelink.light.lamp4` |
| AC companion | `lumi.acpartner.mcn02` |
| Circulation fan | `dmaker.fan.p28` |
| Blender | `chunmi.juicer.a1` |
| Health kettle | `chunmi.health_pot.a1` |
| Air fryer | `careli.fryer.maf07c` |
| Rice cooker | `chunmi.cooker.cmwy3` |

Bluetooth devices, Zigbee / Bluetooth Mesh gateway subdevices and cloud light groups are outside the current direct control scope. Other Wi-Fi models depend on valid credentials, firmware LAN support and available protocol mappings.

Selecting a cooking preset only stages parameters; starting the appliance requires a separate action. Interfaces with unconfirmed parameter semantics do not send guessed commands. Additional HomeKit controls use named switches or presets, and some readings remain available only on the Mac. The AC's current temperature is currently a placeholder based on its target temperature, not a room temperature measurement.

See the [device interface matrix](docs/device-interface-matrix-2026-10-31.md) for permissions, parameters and validation limits. The matrix is currently in Chinese.

## Privacy

MijiaLAN has no project operated cloud backend, advertising or analytics SDK. QR import connects to Xiaomi services. Importing or adding devices may fetch specifications from `miot-spec.org`. Device control uses UDP 54321, and Apple Home accesses the LAN HAP bridge.

Source tokens and preview data are fixtures. Real device registries, Keychain data, pairing codes, diagnostic output and local screenshots are excluded from publication. Diagnostic exports omit tokens and pairing keys but can still contain device names, IDs, readings and timestamps. Review them before sharing.

See the [privacy notes](PRIVACY.en.md) for data flows, CLI precautions and the publication audit scope.

## Development

```bash
swift test
swift build --product mijia-lan
swift run mijia-lan discover
swift run mijia-lan matrix
```

The CLI also provides `info`, `get`, `set`, `call`, `spec` and `status`, which reads a registry from standard input. Run `swift run mijia-lan` without arguments for usage. Discovery hides tokens by default; `--show-tokens` explicitly enables tokens exposed by some old firmware. Token arguments to other commands may enter shell history and process arguments; prefer the app for credential import.

Build the Debug app with `./scripts/build_app.sh debug`, then run the Debug executable with simulated devices:

```bash
MIJIALAN_UI_PREVIEW=1 "$(swift build --show-bin-path)/MijiaLANApp"
```

| Environment variable | Purpose |
| --- | --- |
| `MIJIALAN_UI_PREVIEW=1` | Debug only: simulated devices, in memory credentials, no HomeKit bridge or real discovery |
| `MIJIALAN_EPHEMERAL=1` | In memory credentials and separate preferences; does not read the real Keychain, but can still send network requests |
| `MIJIALAN_SEED_CONFIG=<path>` | Load a local test registry in ephemeral mode; the file may contain credentials |
| `MIJIALAN_DIAGNOSTICS_OUTPUT=<path>` | Export readings and errors; treat the output as private diagnostic data |
| `MIJIALAN_SNAPSHOT=<path>` | Render a panel screenshot; use `MIJIALAN_SNAPSHOT_DELAY` to set the delay in seconds |
| `MIJIALAN_UI_THEME=dark/light` | Choose screenshot appearance |
| `MIJIALAN_UI_PAGE=<did>/settings` | Choose the initial screenshot page; defaults to Home |
| `MIJIALAN_SNAPSHOT_WINDOW=<seconds>` | Open an interactive native preview window |

| Directory | Contents |
| --- | --- |
| `Sources/MijiaLAN` | miIO protocol, discovery, import, credential storage, capabilities and shared controller |
| `Sources/MijiaHomeKitBridge` | HomeKit mapping, bridge and pairing state |
| `Sources/MijiaLANApp` | SwiftUI / AppKit menu bar interface |
| `Sources/mijia-lan` | Command line tools |
| `Tests` | Protocol, capability, security boundary, HomeKit and localization tests |
| `Vendor/hap-swift` | HAP implementation and local fixes, under its original license |

## License and acknowledgments

Original project code is licensed under the [MIT License](LICENSE), copyright iPocket-APP. Third party components retain their own licenses:

- [MenuBarMijia](https://github.com/jryang1997/MenuBarMijia)'s `MijiaCore` (MIT) provides QR login, MIoT specification parsing, device synthesis and HomeStore.
- [hap-swift](https://github.com/acumen-dev/hap-swift) (Apache-2.0) provides HomeKit Accessory Protocol support; the vendored copy includes local fixes.
- Apple Swift libraries and other transitive dependencies are listed in [third party notices](THIRD_PARTY_NOTICES.md).

This is a community project with no affiliation with Xiaomi, Mijia or Apple, and no HomeKit / MFi certification. The MIT license does not grant rights to third party protocols, services or trademarks.

## Matter / Aqara bridge

Settings offers independent HomeKit and Matter bridges, each with its own device selection. Both use the App's shared controller.
Matter mappings include lights with brightness and color temperature, outlets, fans, selected purifiers and sensors.
Pairing and runtime controls are integrated in the App. Apple Home also accepts Matter devices.
See [MatterBridge/README.md](MatterBridge/README.md) for builds and limits (Chinese). Commit `9060d6d` passed CLI/App compilation and all Swift tests on a local Mac. Native UI behavior, full App packaging/signing and M200 pairing remain unverified.
