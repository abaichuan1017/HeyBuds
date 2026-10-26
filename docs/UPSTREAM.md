# Upstream provenance

HeyBuds preserves upstream license notices and uses public file fingerprints in [upstream-sources.json](upstream-sources.json). The SHA-256 values identify the local reference snapshot used for the port; no unverified Git commit or release tag is invented.

| Reference | License | Use |
| --- | --- | --- |
| [OppoPodsManager](https://github.com/Zhaoyi-ya/OppoPodsManager) | GPL-3.0-or-later | Brand protocols, capability/model tables, state and command semantics |
| [EncoDeck](https://github.com/TIANLI0/EncoDeck) | GPL-3.0-only | X4 configuration and public protocol fixtures at `ba5db26753eceacaa4ba48ab3b87067cc0ec7da4` |
| [Realme TWS Mac Controller](https://github.com/anikket-b/Realme-TWS-Mac-Controller) | MIT | T500 Pro mappings, captured fixtures, menu bar / RFCOMM reference; full notice in Licenses |
| [Buds for macOS](https://github.com/GewoonJaap/oneplus-buds-macos) | PolyForm Noncommercial 1.0.0 | Visual reference only; no code or assets copied |

The retained OPPO model/EQ resources and [`docs/reference/VivoDeviceModels.json`](reference/VivoDeviceModels.json) are byte-identical to the frozen source files. `MigratedModels.json` is generated from the reference tables and retains vivo variants and Huawei capability declarations. `scripts/import-brand-models.py` is an optional maintainer tool; it requires a sibling `OppoPodsManager-main` checkout matching the fingerprints. The original vivo table is reference-only; the app reads the normalized entries in `MigratedModels.json`. Normal builds use the committed resources and require no reference projects.

For X4, `docs/reference/EncoDeck-X4.cs` preserves the exact `06EC10` entry and source version (`117006008`) from [EncoDeck's generated catalog](https://github.com/TIANLI0/EncoDeck/blob/ba5db26753eceacaa4ba48ab3b87067cc0ec7da4/src/EncoDeck.Protocol/Oppo/Models/OppoCatalog.g.cs). The excerpt header identifies the extraction; unrelated model entries are omitted. Run `python3 scripts/import-encodeck-x4.py` to reproduce `EncoDeckModels.json`. File hashes and the frozen commit are recorded in `upstream-sources.json`; the original OPPO/EQ resources remain unchanged. The upstream Windows hardware report is separate from HeyBuds macOS validation.

The `airpods.pro` icon and system materials are provided by macOS; the generator and full third-party notice are included. Brand names identify interoperability, not endorsement or affiliation.

## 0.5.0 protocol references

The following references inform the Samsung, Google, Bose, Nothing/CMF and additional Sony profiles. License descriptions refer to the reference versions used for this adaptation. Source versions and file fingerprints belong in [upstream-sources.json](upstream-sources.json); full notices are retained in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and `Licenses/`.

| Reference | License | Use |
| --- | --- | --- |
| [Budsy](https://github.com/vedatkilic/budsy) | MIT | Samsung service, framing, handshake and Buds4 Pro control semantics |
| [GalaxyBudsClient](https://github.com/timschneeb/GalaxyBudsClient) | GPL-3.0 | Samsung model/revision layouts, battery flags, EQ and touch-lock fields |
| [PixelBudsMacOS](https://github.com/KashaMalaga/PixelBudsMacOS) | MIT; pbpctrl-derived references retain Apache-2.0 OR MIT | Maestro service, HDLC/RPC framing, settings and public protocol fixtures |
| [pbpctrl](https://github.com/qzed/pbpctrl) | Apache-2.0 OR MIT | Maestro protobuf definitions, Pigweed hashes, logical routes and setting values |
| [MagicBuds](https://github.com/artistro08/MagicBuds) | MIT; third-party components have separate notices | Pixel Buds Pro 2 protocol observations and absent-battery-field semantics; no UI assets used |
| [bosectl](https://github.com/aaronsb/bosectl) | MIT | Bose BMAP framing, RFCOMM service and QuietComfort control fields |
| [bozo](https://github.com/NerdySouth/bozo) | MIT | Bose BMAP mode and per-index setting references; not used for Ultra Earbuds (2nd Gen) transport |
| [bosectl-android](https://github.com/depau/bosectl-android) | GPL-3.0 | Ultra Earbuds (2nd Gen) secure BLE transport, battery and noise-control fields |
| [swift-nothing-ear](https://github.com/bestK1ngArthur/swift-nothing-ear) | GPL-3.0 | Nothing/CMF model capability and protocol documentation |
| [nothing-x-macos](https://github.com/nikiomori/nothing-x-macos) | GPL-3.0 | Nothing dedicated RFCOMM service, packet and state references; no product images used |
| [openNothing](https://github.com/Evergaster/openNothing) | MIT declared in README/project metadata; standalone license absent from the reference snapshot | CMF Buds Pro 2 packet/CRC and readback facts only; no source code copied |
| [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) | MIT; generated files retain their own provenance | Sony MDR V1/V2 framing, capability and state definitions, including XM3/XM4 profiles |
| [sonyctl](https://github.com/DaanHessen/sonyctl) | AGPL-3.0 | Documented WH-XB910N protocol facts only; no AGPL source code copied |
| [sony-ult-ctl](https://github.com/Leonard013/sony-ult-ctl) | MIT | ULT WEAR model and noise-control facts; device-specific addresses and fixed RFCOMM channels are not reused |

The Sony implementation uses the MIT-licensed SonyHeadphonesClient reference and independently expressed protocol facts; it does not incorporate AGPL code from sonyctl. openNothing is likewise used only to cross-check protocol facts because the reference snapshot does not contain the standalone license linked by that project. Other references retain their applicable notices; a repository-wide license label does not replace notices on individual or derived files.

These references establish protocol and model evidence. Their hardware observations do not establish HeyBuds/macOS compatibility: all 16 models added in 0.5.0 have initial support and still require verification on the corresponding devices.
