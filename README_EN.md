# HeyBuds

<img src="docs/HeyBuds.png" alt="HeyBuds" width="112">

**Your earbuds, a click away.**

A native Apple Silicon macOS menu bar app for earbud battery levels, noise control, sound settings and connected hosts. Built with SwiftUI and native Liquid Glass controls, with Chinese and English interfaces.

[Download v0.3.0](https://github.com/abaichuan1017/HeyBuds/releases/tag/v0.3.0) · [简体中文](README.md) · [Compatibility](docs/COMPATIBILITY.md) · [Changelog](CHANGELOG.md)

Version **0.3.0**. Previously named EncoBar. Protocols and catalogs are primarily ported from [OppoPodsManager](https://github.com/Zhaoyi-ya/OppoPodsManager), with upstream attribution and GPL licensing preserved.

## Features

- Separate left, right and case battery readings, charging flags, unknown states and a single-battery layout where appropriate.
- Model-specific noise cancellation, transparency and strength controls.
- Capability-gated EQ, custom EQ, spatial audio, gaming, wear detection and other supported controls.
- Connected-host lists, connect/disconnect and supported priority operations.
- Connection cards, low-battery notifications, background mode, launch at login and reconnection backoff.
- Device readback confirms settings. A generic ACK does not mean that a setting was applied.
- No network telemetry, built-in updater or access to system Bluetooth pairing keys.

## Compatibility

| Family | Catalog | Scope |
| --- | --- | --- |
| OPPO / OnePlus / realme | 137 product IDs | RFCOMM / BLE, battery, noise, sound, feature switches, hosts |
| vivo / iQOO | 43 display models, 87 original variants | GAIA, battery, noise, EQ, spatial / gaming, wear, find, hosts |
| HUAWEI | 24 model routes | Battery, model-specific noise, EQ, selected custom EQ and dual connection |
| Xiaomi / Redmi | Family detection | Battery and optional authentication; latency control requires valid readback |
| EDIFIER | W820NB, W200BT, EDIFIER rules | SPP battery and noise; BLE-only models are not connected |
| Apple / Beats | 18 advertisement model mappings | Read-only plaintext BLE battery, charging and wear |

**An imported catalog is not hardware certification.** The 226 records include family matching rules, rather than 226 independently verified products. Newly added families have source and simulated-protocol coverage; hardware behavior remains unverified. Availability depends on the device, firmware, macOS service exposure and valid responses. Anonymous or encrypted AirPods advertisements are not assigned to the selected device. See [compatibility](docs/COMPATIBILITY.md) and [porting scope](docs/ALL_BRANDS.md).

## Install

Requires an **Apple Silicon Mac with macOS 27 or later**. Intel builds are not provided.

1. Extract `HeyBuds-arm64.zip` and place `HeyBuds.app` in Applications.
2. Pair your earbuds in macOS Bluetooth settings and quit other controllers.
3. Open HeyBuds and allow Bluetooth access when prompted. Notifications are optional.
4. Click the menu bar icon. Leave model detection on Automatic unless identification is incorrect.

Local builds are ad-hoc signed and are not notarized. Use the normal macOS Open flow when required; do not disable system protections. Launch at login needs a stable installation path.

Quit the legacy EncoBar before upgrading. HeyBuds migrates recognized local preferences once and preserves existing HeyBuds settings. The new bundle identifier is `local.heybuds.app`; Bluetooth, notifications and login registration follow the new app's system permissions.

## Build

Requires **Swift 6.4 and the macOS 27 SDK** on Apple Silicon. A matching Command Line Tools or Xcode installation works. No reference checkout or third-party Swift dependencies are required for a normal build.

```sh
swift test
bash scripts/build.sh
open dist/HeyBuds.app
```

Outputs: `dist/HeyBuds.app` and `dist/HeyBuds-arm64.zip`. Previous apps are preserved in `dist/backups/`. Set `HEYBUDS_SIGN_IDENTITY` to use an existing identity. The script does not install, notarize or publish the app.

```sh
python3 scripts/package-source.py
```

Creates `releases/HeyBuds-v0.3.0-source.zip`, a file manifest and checksums from an explicit public-file allowlist. Local diagnostics, preferences, build products and backups are excluded. See [release preparation](docs/RELEASING.md). GitHub workflows are included; hosted execution has to be verified after upload.

## Diagnostics and contributing

```sh
swift run heybuds-probe catalog
swift run heybuds-probe devices
swift run heybuds-probe read
swift run heybuds-probe read --ble
```

Quit other controllers before hardware probing. The terminal needs Bluetooth permission. `--ble` applies to the OPPO-family GATT transport. In-app diagnostics redact device addresses, host names and raw payloads by default; inspect exports before sharing.

Modules: `HeyBudsProtocol`, `HeyBudsBluetooth`, `HeyBuds` and the `heybuds-probe` executable. See [architecture](docs/ARCHITECTURE.md), [contributing](CONTRIBUTING.md) and [validation](docs/VALIDATION.md).

## License

**GPL-3.0-or-later**. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md). Protocol work is primarily based on OppoPodsManager, with MIT references from [Realme TWS Mac Controller](https://github.com/anikket-b/Realme-TWS-Mac-Controller). No PolyForm-licensed Buds for macOS code or assets are included. Upstream fingerprints are recorded in [UPSTREAM.md](docs/UPSTREAM.md).

An independent community project, unaffiliated with Apple or the listed earbud brands.
