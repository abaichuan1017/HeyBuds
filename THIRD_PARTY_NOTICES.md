# Third-party notices

HeyBuds is distributed under **GPL-3.0-or-later**. See LICENSE.

## OppoPodsManager

- Source: https://github.com/Zhaoyi-ya/OppoPodsManager
- License: GPL-3.0-or-later. Copyright belongs to the upstream contributors.
- Frozen reference and runtime-resource fingerprints: `docs/upstream-sources.json`. A reference checkout is not required to build HeyBuds.
- Adapted into Swift: OPOv1 framing, command capability bitmap, model catalog interpretation, noise mappings, battery/placement, feature switches, EQ, bass engine, spatial/game sound and remote device management.
- Also adapted: vivo / iQOO GAIA profiles and capabilities, Huawei legacy/MBB framing and model/ANC/EQ tables, Xiaomi RCSP framing and public challenge-response algorithm, Edifier framing/battery/noise, and Apple plaintext advertisement/model decoding.
- `VivoDeviceModels.json` is preserved byte-for-byte. `MigratedModels.json` is generated from the frozen upstream data and C# tables by `scripts/import-brand-models.py`; it retains vivo variants and Huawei capability declarations.
- `DeviceModels.json`, `EqModeNames.json`, `EqModeNames.en.json` are retained upstream resources. Their original source annotations remain in the files; no independent claim is made to manufacturer artwork or trademarks.

## Realme TWS Mac Controller

- Source: https://github.com/anikket-b/Realme-TWS-Mac-Controller
- MIT License. Copyright (c) 2026 Aniket Budhwani.
- Full notice: `Licenses/Realme-MIT.txt`.
- The RFCOMM/menu bar lifecycle, T500 Pro mappings and captured protocol test fixtures informed this implementation. Circular noise buttons and equal-width ANC strength capsules are adapted from its SwiftUI panel, with the same SF Symbols. The framing parser, buffer ownership and session routing were rewritten.

## Buds for macOS

- Reference: https://github.com/GewoonJaap/oneplus-buds-macos
- Upstream license: PolyForm Noncommercial 1.0.0.
- Used as a visual/information-architecture reference only. No source code or assets from that project are included. Shared Bluetooth protocol constants describe interoperability, not a copied implementation.

No affiliation with OPPO, OnePlus, realme, vivo, iQOO, Huawei, Xiaomi, Redmi, Edifier or Apple. The app icon combines the original blue gradient background with Apple's `airpods.pro` SF Symbol, the same system asset used by the menu bar. SF Symbols and system materials are provided by macOS.
