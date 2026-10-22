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

No affiliation with OPPO, OnePlus, realme, vivo, iQOO, Huawei, Xiaomi, Redmi, Edifier or Apple. The app icon combines the original blue gradient background with Apple's `airpods.pro` SF Symbol, the same system asset used by the menu bar. SF Symbols and system materials are provided by macOS.
