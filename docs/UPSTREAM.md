# Upstream provenance

HeyBuds preserves upstream license notices and uses public file fingerprints in [upstream-sources.json](upstream-sources.json). The SHA-256 values identify the local reference snapshot used for the port; no unverified Git commit or release tag is invented.

| Reference | License | Use |
| --- | --- | --- |
| [OppoPodsManager](https://github.com/Zhaoyi-ya/OppoPodsManager) | GPL-3.0-or-later | Brand protocols, capability/model tables, state and command semantics |
| [Realme TWS Mac Controller](https://github.com/anikket-b/Realme-TWS-Mac-Controller) | MIT | T500 Pro mappings, captured fixtures, menu bar / RFCOMM reference; full notice in Licenses |
| [Buds for macOS](https://github.com/GewoonJaap/oneplus-buds-macos) | PolyForm Noncommercial 1.0.0 | Visual reference only; no code or assets copied |

The retained OPPO model/EQ resources and `VivoDeviceModels.json` are byte-identical to the frozen source files. `MigratedModels.json` is generated from the reference tables and retains vivo variants and Huawei capability declarations. `scripts/import-brand-models.py` is an optional maintainer tool; it requires a sibling `OppoPodsManager-main` checkout matching the fingerprints. Normal builds use the committed resources and require no reference projects.

The `airpods.pro` icon and system materials are provided by macOS; the generator and full third-party notice are included. Brand names identify interoperability, not endorsement or affiliation.
