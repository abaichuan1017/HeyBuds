<div align="center">

<img src="docs/HeyBuds.png" alt="HeyBuds" width="112">

# HeyBuds

**Your earbuds, a click away.**

A native macOS menu bar companion for your earbuds

[Download](https://github.com/abaichuan1017/HeyBuds/releases/latest) · [简体中文](README.md) · [Supported earbuds](#supported-earbuds) · [Install and use](#install-and-use)

</div>

Check battery levels, switch noise modes, adjust sound and manage connected devices from the menu bar. Available in Chinese and English.

## Screenshots

<table>
  <tr><th>Main panel</th><th>Advanced features</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/home.png" alt="HeyBuds main panel with battery levels, noise control and connected devices" width="300"></td>
    <td valign="top"><img src="docs/images/advanced.png" alt="HeyBuds advanced features with EQ, spatial audio, gaming and wear detection" width="300"></td>
  </tr>
</table>

## Features

- Left, right and case battery levels, charging and wear status.
- Noise cancellation, transparency and ANC strength controls.
- EQ presets, custom EQ, spatial audio and gaming mode.
- Connected-device lists and supported connection controls.
- Connection pop-ups, low-battery alerts, automatic reconnection, background mode and launch at login.

## Supported earbuds

| Brand | Selected models |
| --- | --- |
| OPPO | Enco Air5 Pro, Air5, Air4 Pro, Air4, Air3 Pro, X3, X3i, X3s, X2, Free4, Clip, Clip2 |
| OnePlus | Buds Pro 3, Pro 2, Pro, Buds 4, Buds 3, Nord Buds 4, Nord Buds 3 Pro, Buds Ace 3, Open Buds |
| realme | Buds Air8 Pro, Air8, Air7 Pro, Air7, Air6 Pro, Air6, T500 Pro, T500, T310, T300, Buds Clip |
| vivo | TWS 5 Pro, TWS 5 Hi-Fi, TWS 5, TWS 4 Hi-Fi, TWS 4, TWS 3 Pro, TWS 3, TWS Air3 Pro, TWS Neo |
| iQOO | TWS 5, TWS 5e, TWS 5i, TWS 2, TWS 1, TWS Air3 Pro, TWS Air3, TWS Air2 |
| HUAWEI | FreeBuds Pro 5, Pro 4, Pro 3, Pro 2, FreeBuds 6i, 5i, 7i, FreeClip 2, FreeClip, FreeLace Pro 2 |
| Xiaomi / Redmi | Xiaomi and Redmi family detection |
| EDIFIER | W820NB, W200BT and EDIFIER devices using SPP |
| Apple / Beats | AirPods 1–4, AirPods Pro 1–3, AirPods Max, Beats Fit Pro, Powerbeats Pro, Beats Flex, Beats Solo 3 |

[Browse the full model list](docs/SUPPORTED_DEVICES.md)

These models come from the integrated catalog and have not all been tested on hardware. Features vary by model and firmware. AirPods and Beats support status reading only. See [compatibility](docs/COMPATIBILITY.md).

## Install and use

Requires an **Apple Silicon Mac running macOS 27 or later**.

### Install

1. Download `HeyBuds-arm64.zip` from [Releases](https://github.com/abaichuan1017/HeyBuds/releases/latest).
2. Extract the ZIP and drag `HeyBuds.app` to Applications.
3. Open HeyBuds and allow Bluetooth access when prompted.

The app is not yet notarized. If macOS blocks it, confirm that you downloaded it from this repository and follow [Apple's instructions](https://support.apple.com/en-us/102445) to choose Open Anyway in System Settings → Privacy & Security.

### Use

1. Pair and connect your earbuds in macOS Bluetooth settings, then quit other earbud controllers.
2. Click the HeyBuds menu bar icon and select your earbuds at the top. If controls are offline, click the power button in the upper-right corner.
3. Check battery levels and switch noise modes in the main panel. Open Advanced features for sound settings or Connected devices to manage connections.
4. Enable automatic reconnection, low-battery alerts or launch at login in Settings. Allow notifications if you want alerts.

### Troubleshooting

- **Earbuds missing:** Check their connection in macOS Bluetooth settings, then choose Refresh devices from the device menu.
- **Battery levels or controls missing:** Keep the earbuds nearby and click the refresh button at the bottom. Some controls are available only on specific models.
- **Upgrading from EncoBar:** Quit the old app before opening HeyBuds. Existing preferences migrate automatically.

## Build from source

Requires Swift 6.4 and the macOS 27 SDK.

```sh
git clone https://github.com/abaichuan1017/HeyBuds.git
cd HeyBuds
swift test
bash scripts/build.sh
open dist/HeyBuds.app
```

[Contributing](CONTRIBUTING.md) · [Architecture](docs/ARCHITECTURE.md) · [Changelog](CHANGELOG.md) · [Report an issue](https://github.com/abaichuan1017/HeyBuds/issues)

## License and credits

Licensed under [GPL-3.0-or-later](LICENSE). Protocols and model data are primarily based on [OppoPodsManager](https://github.com/Zhaoyi-ya/OppoPodsManager), with references from [Realme TWS Mac Controller](https://github.com/anikket-b/Realme-TWS-Mac-Controller). See [third-party notices](THIRD_PARTY_NOTICES.md) for full attribution.

HeyBuds is an independent community project, unaffiliated with the listed brands.
