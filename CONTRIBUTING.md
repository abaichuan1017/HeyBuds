# Contributing to HeyBuds

Read [AGENTS.md](AGENTS.md), [architecture](docs/ARCHITECTURE.md) and [compatibility](docs/COMPATIBILITY.md) first.

## Development

Use Apple Silicon, Swift 6.4 and the macOS 27 SDK:

```sh
swift test
bash scripts/build.sh
python3 scripts/audit-source.py
```

Keep wire formats and parsers in `HeyBudsProtocol`, transport and sessions in `HeyBudsBluetooth`, and presentation in `HeyBuds`. All UI strings use the Chinese/English helper. Preserve accessibility, reduced-motion and reduced-transparency behavior.

## Protocol changes

- Provide upstream sources or consented, redacted evidence for new commands and models.
- Never guess RFCOMM channels, access OTA services, expose unpairing or send unexplained opcodes.
- Gate features by model and valid device responses. Keep absent, unknown, stale and zero states distinct.
- Validate write results through readback where available. Describe ACK-only operations as sent, rather than confirmed.
- Add meaningful fixtures for protocol changes: malformed frames, fragmentation, model differences and session cancellation where relevant.
- Run a single controller at a time during hardware work. A passing mock does not prove compatibility with a physical device.

## Issues and pull requests

Describe the model, firmware, macOS version, expected behavior and observed result. State whether evidence comes from a real device, a simulated session or source inspection. Include reproduction steps and the checks actually run.

Never submit pairing keys, credentials, Bluetooth addresses, host names, raw captures, private diagnostics or unrelated personal files. Inspect redacted exports before attaching them. Keep changes narrow and retain upstream attribution. Contributions are provided under GPL-3.0-or-later, consistent with this project.
