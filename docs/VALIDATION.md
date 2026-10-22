# Validation

Checked locally on 2026-10-22, Asia/Shanghai: Apple Silicon, macOS 27.2, Apple Swift 6.4. These results cover source, simulated sessions and packaging; complete application launch time and physical-device reconnection were not measured.

| Check | Result |
| --- | --- |
| Automated tests | 65 passed: 24 protocol, 34 session, 7 presentation / preference-migration |
| Model lookup regression | 336 names, aliases and fallback inputs produce the same results as commit `512cdf5`; all 226 catalog records remain |
| Resource integrity | Source catalog fingerprints unchanged; original vivo table moved to `docs/reference/`; compact bundled JSON has identical values |
| Application ZIP | 2,187,148 → 1,435,752 bytes, down 34.4% |
| Application files | 6,162,736 → 2,721,872 bytes, down 55.8%; 12 distributable files |
| Executable | 4,285,504 → 1,605,392 bytes; arm64, strict ad-hoc signature verification passed |
| Icon | All image sizes, decoded PNG streams and metadata unchanged; chunk CRCs verified |
| Release diagnostics | Developer hardware-exercise and preview code excluded from release compilation; normal redacted diagnostic export remains |

An optimized, hardware-free catalog benchmark ran 3,360 lookups over those 336 inputs: 851.26 ms before, 3.67 ms after. This measures model lookup only. Full catalog initialization remained about 34 ms and now runs away from the main actor; the panel is created on first use. Results depend on the local environment and do not measure time to Bluetooth readiness.

The package checks include source allowlisting, JSON/resource fingerprints, relative documentation links, bundled file allowlisting, runtime JSON equivalence, ZIP CRC/content equality and license preservation. The source archive is also extracted and tested without sibling reference projects or an existing build cache. Commands are in [RELEASING.md](RELEASING.md).

The toolchain still prints missing search-directory linker warnings; builds and tests succeed without changing system settings. Ad-hoc signing is not notarization. No new physical-device acceptance is claimed; the earlier Air5 Pro observations do not establish compatibility with other models. See [compatibility](COMPATIBILITY.md).

## Historical Air5 Pro evidence

The source catalog snapshot at `512cdf5` retained these observations for OPPO Enco Air5 Pro, product ID `06C410`. They are preserved here when removing the duplicate `docs/models.json`; they were not repeated in this maintenance run. “本次” below refers to that historical observation, not 2026-10-22.

- BLE 控制连接
- 产品 ID 读取
- 左右耳电量读取
- 佩戴状态读取
- 通透写入与回读
- 深度降噪写入与回读
- EQ 预设 2 写入与回读
- 手机状态同步（用户确认）
- 充电盒电量读取（本次 60%，用户确认显示正常）
