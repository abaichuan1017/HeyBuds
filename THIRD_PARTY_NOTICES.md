# Third-party notices

HeyBuds is distributed under **GPL-3.0-or-later**. See LICENSE.

## OppoPodsManager

- Source: https://github.com/Zhaoyi-ya/OppoPodsManager
- License: GPL-3.0-or-later. Copyright belongs to the upstream contributors.
- Frozen reference and runtime-resource fingerprints: `docs/upstream-sources.json`. A reference checkout is not required to build HeyBuds.
- Adapted into Swift: OPOv1 framing, command capability bitmap, model catalog interpretation, noise mappings, battery/placement, feature switches, EQ, bass engine, spatial/game sound and remote device management.
- Also adapted: vivo / iQOO GAIA profiles and capabilities, Huawei legacy/MBB framing and model/ANC/EQ tables, Xiaomi RCSP framing and public challenge-response algorithm, and Edifier framing/battery/noise.
- `docs/reference/VivoDeviceModels.json` is preserved byte-for-byte in the source distribution. The app reads `MigratedModels.json`, generated from the frozen upstream data and C# tables by `scripts/import-brand-models.py`; it retains vivo variants and Huawei capability declarations.
- `DeviceModels.json`, `EqModeNames.json`, `EqModeNames.en.json` are retained upstream resources. Source files preserve their original bytes; application copies use compact JSON with the same values and source annotations. No independent claim is made to manufacturer artwork or trademarks.

## EncoDeck

- Source: https://github.com/TIANLI0/EncoDeck
- Frozen commit: `ba5db26753eceacaa4ba48ab3b87067cc0ec7da4` (1.0.1).
- License: GPL-3.0-only. Copyright belongs to the EncoDeck contributors; full license in `Licenses/EncoDeck-GPL-3.0.txt`.
- Thanks to EncoDeck and its contributors for publishing the OPPO Enco X4 configuration and public protocol fixtures.
- `docs/reference/EncoDeck-X4.cs` retains only the exact X4 entry and catalog version from `src/EncoDeck.Protocol/Oppo/Models/OppoCatalog.g.cs`. `scripts/import-encodeck-x4.py` converts it into `EncoDeckModels.json`, preserving its model-specific facts. Existing OppoPodsManager resource bytes are unchanged except for the separately generated multi-brand catalog, from which Apple / Beats entries were removed.
- Public X4 frame fixtures from `tests/EncoDeck.Tests/Protocol/EncoX4CaptureTests.cs` are adapted in `Tests/HeyBudsProtocolTests/EncoX4Tests.swift`, which retains GPL-3.0-only attribution. No personal device lists, manufacturer artwork or binaries are copied.
- HeyBuds-authored code remains GPL-3.0-or-later; the included EncoDeck material is GPL-3.0-only, and the combined distribution is under GPL version 3.

## Realme TWS Mac Controller

- Source: https://github.com/anikket-b/Realme-TWS-Mac-Controller
- MIT License. Copyright (c) 2026 Aniket Budhwani.
- Full notice: `Licenses/Realme-MIT.txt`.
- The RFCOMM/menu bar lifecycle, T500 Pro mappings and captured protocol test fixtures informed this implementation. Circular noise buttons and equal-width ANC strength capsules are adapted from its SwiftUI panel, with the same SF Symbols. The framing parser, buffer ownership and session routing were rewritten.

## Sony MDR references

- [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient), [SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge) and [HeadBridge](https://github.com/herenickname/HeadBridge) informed the handwritten Swift MDR framing, V2 handshake, function discovery, battery and noise-control implementation. MIT notices and copyrights are preserved in `Licenses/Sony-MIT.txt`.
- [Sony Device Center](https://github.com/marconvcm/sony-device-center) was used to cross-check model profiles and V2 payloads. No C++ client or binary is bundled.
- Exact revisions and source fingerprints are recorded in `docs/upstream-sources.json`. Only explicitly listed V1/V2 profiles are enabled; upstream support reports do not establish HeyBuds hardware compatibility. Manufacturer applications, extracted metadata, artwork and raw device captures are not included.

## Sparkle

- Source: https://github.com/sparkle-project/Sparkle (2.10.0).
- MIT / included component licenses; complete notices in `Licenses/Sparkle.txt`.
- Provides the native update, download and installation interface. Thanks to the Sparkle contributors.

## GitHub mark

- Official asset: https://brand.github.com/foundations/logo (GitHub Invertocat, black PDF).
- Used unchanged as a monochrome project-link button under GitHub's permitted linking use. GitHub trademarks remain the property of GitHub, Inc.; no endorsement is implied.

## Buds for macOS

- Reference: https://github.com/GewoonJaap/oneplus-buds-macos
- Upstream license: PolyForm Noncommercial 1.0.0.
- Used as a visual/information-architecture reference only. No source code or assets from that project are included. Shared Bluetooth protocol constants describe interoperability, not a copied implementation.

No affiliation with OPPO, OnePlus, realme, vivo, iQOO, Huawei, Xiaomi, Redmi, Edifier, Sony or Apple. The app icon combines the original blue gradient background with Apple's `airpods.pro` SF Symbol, the same system asset used by the menu bar. SF Symbols and system materials are provided by macOS.

## Samsung

- [Budsy](https://github.com/vedatkilic/budsy) (MIT, Copyright 2026 Vedat Kılıç) and [GalaxyBudsClient](https://github.com/timschneeb/GalaxyBudsClient) (GPL-3.0) informed modern SPP framing, CRC, revision-specific status fields, preset EQ, touch-lock preservation and Buds4 Pro ANC levels. See `Licenses/Samsung-MIT.txt` and the GPL license included with HeyBuds.
- The parser, request lifecycle and readback checks are handwritten; firmware transfer, reset, serial-number requests and upstream application assets are excluded.

## Google Maestro

- [PixelBudsMacOS](https://github.com/KashaMalaga/PixelBudsMacOS) (MIT, Jesús Ramírez Ramos) and [pbpctrl](https://github.com/qzed/pbpctrl) (MIT or Apache-2.0, Maximilian Luz) informed the handwritten bounded protobuf subset, Pigweed HDLC/RPC framing, setting IDs and preset curves. MIT notices are included in `Licenses/Google-MIT.txt`.
- No generated protobuf code, Google application resources or account services are bundled. The Pigweed wire layout is used for interoperability.

## Additional Sony profiles

- [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT) supplies V1 protocol definitions. [sony-ult-ctl](https://github.com/Leonard013/sony-ult-ctl) (MIT, Copyright 2026 Leonard013) informs ULT payload fields; its full notice is retained in `Licenses/Sony-ULT-MIT.txt` and `SonyProtocol.swift`.
- [sonyctl](https://github.com/DaanHessen/sonyctl) protocol documentation was used only for XB910N interoperability facts. No AGPL implementation is copied or bundled.

New brand names identify interoperability only. No affiliation with Samsung, Google, Bose, Nothing or CMF is implied.

## Bose BMAP

- [bosectl](https://github.com/aaronsb/bosectl) and [bozo](https://github.com/NerdySouth/bozo) (MIT) provide model-specific battery/mode/CNC references. Full notices are in `Licenses/Bose-MIT.txt`.
- [bosectl-android](https://github.com/depau/bosectl-android) (GPL-3.0-or-later) informs secure GATT endpoints, segmentation and Ultra Earbuds 2 corrections. The Swift code is newly implemented with bounded decoders and explicit GET readback; no fixed RFCOMM channels, pairing repair or manufacturer binaries are copied.

## Nothing / CMF

- [swift-nothing-ear](https://github.com/bestK1ngArthur/swift-nothing-ear) and [nothing-x-macos](https://github.com/nikiomori/nothing-x-macos) (GPL-3.0) provide model-specific protocol and capability references. Thanks to bestK1ngArthur, nikiomori, Daniel and their contributors. The full GPL license is included as `LICENSE`.
- [EarA-linux](https://github.com/oneydef/EarA-linux) (GPL-3.0-or-later) and [omarchy-headphones](https://github.com/ncr/omarchy-headphones) (MIT, Jacek Becela) supply additional protocol facts. [openNothing](https://github.com/Evergaster/openNothing) is used only for protocol facts because the reference snapshot lacks its declared standalone license. No AGPL or ambiguously licensed implementation is copied.
- Source files, checksum policies, identity gates and remaining field ambiguities are documented in [Nothing provenance](docs/licenses/Nothing.md). No manufacturer artwork, serial numbers or personal captures are included.

[MagicBuds](https://github.com/artistro08/MagicBuds) (MIT, Copyright 2026 Devin Green) supplied Pixel Buds Pro 2 protocol cross-checks. Its full notice is retained in `Licenses/Google-MIT.txt`.
