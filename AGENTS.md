# HeyBuds

Native arm64 macOS 27+ menu bar controller for OPPO / OnePlus / realme, vivo / iQOO, Huawei, Xiaomi / Redmi, Edifier and Apple.

- Build and test: `swift test`; `bash scripts/build.sh` packages the application.
- Route each brand to its own service UUID and wire codec. Apple uses passive advertisements; never send OPPO commands to another brand. Keep capability keys distinct from wire command IDs.
- HeyBudsProtocol contains pure framing, models and parsers. HeyBudsBluetooth owns transport and sessions. HeyBuds owns presentation and system integration.
- Keep reference projects and ZIPs outside this folder unchanged. `docs/upstream-sources.json` records public upstream/resource fingerprints; local historical snapshots stay under ignored backups/.
- GPL-3.0-or-later. Preserve upstream attribution. Do not copy code or assets from the PolyForm-licensed Buds project.
- Never guess RFCOMM channels, access OTA services, send unknown opcodes or expose unpair operations.
- Do not mark a hardware setting successful from a generic ACK. Read back when available. Unknown, absent and stale state are distinct.
- Only one running controller/probe may own a device session. Hardware checks require the user's Bluetooth permission; tests do not prove hardware compatibility.
- Never commit device addresses, host names, raw captures or personal logs. Export diagnostics redacted by default.
- UI strings use the bilingual localization helper. Respect reduced motion/transparency. No network telemetry or self-updater.
