# Validation

Protocol and session tests cover simulated device responses. Application checks cover presentation, preference migration and signed update delivery. See [Actions](https://github.com/abaichuan1017/HeyBuds/actions) for build status.

The macOS 15 prerelease compiles with a macOS 15 deployment target. Automated checks cover both control styles' layout and compatibility-style rendering in light/dark appearance with opaque/material surfaces on the development system. Liquid Glass uses native compositing and requires a window for visual inspection. These checks do not substitute for running the packaged application on macOS 15; runtime, Bluetooth permissions, reconnect and sleep/wake acceptance there remain pending.

Enco Air5 Pro has historical read/write observations. X4 coverage uses public EncoDeck frames and simulated sessions; HeyBuds/macOS hardware acceptance is still pending. Catalog entries do not guarantee hardware compatibility.

Sony WF-1000XM5, WH-1000XM5 and WH-CH720N coverage uses framing/parser fixtures and simulated MDR V2 sessions. Hardware acceptance for each model remains pending.

Build and release instructions are in [RELEASING.md](RELEASING.md). Model and feature limits are in [COMPATIBILITY.md](COMPATIBILITY.md).

The 0.5 expansion adds model-specific parser and simulated-session coverage for Samsung, Google Maestro, Bose BMAP, Nothing/CMF and Sony MDR V1/V2 profiles. Cases include invalid/truncated fields, checksum failures, fresh readback, delayed write completion, cancellation and stale-session events. BLE tests exercise segmentation without starting CoreBluetooth discovery.

All 16 newly listed models still need hardware acceptance: proprietary service discovery, model/firmware identity, actual battery/charging reports, each exposed setting and phone synchronization, plus disconnect/reconnect and sleep/wake behavior. Bose Ultra Earbuds 2 left/right component mapping remains unresolved. Local simulation is not a hardware compatibility claim.

The subsequent [39-model desktop-controller expansion](DESKTOP_EXPANSION.md) adds protocol vectors and simulated sessions for Soundcore, Sennheiser, JBL, HONOR routing and the additional Sony, Samsung, QC35 and Nothing profiles. Coverage includes model-specific battery layouts, Soundcore's upstream EQ packet, M5/C700N firmware restrictions, Sony adaptive-field preservation, original Galaxy Buds framing, QC35's absence of transparency, and read-only Nothing product-ID verification before opening the control service. M4 peer operations check fresh capacity, target identity and continued connectivity of the current host.

These checks do not discover, connect to or control physical Bluetooth devices. All 39 profiles need model/firmware-specific hardware acceptance. In particular, newer Samsung shared status fields, Nothing product variants/checksum conventions, JBL transport behavior and phone synchronization remain unverified on HeyBuds.

The [explicit Xiaomi profiles](XIAOMI_SUPPORT.md) add published Mac frame vectors, independent authentication vectors, strict/fragmented frame parsing, mutual-authentication completion and model-bound simulated sessions. Cases cover identity mismatch, missing or malformed fresh readback, non-ANC capability gates, opposite-ear/unknown-gesture preservation, custom-EQ selection and bounds, spatial preference preservation, worn-ear find rejection and stale callbacks. System-only profiles use synthetic connected-device reports and never send private control frames. These are software checks; all newly listed Xiaomi models still require HeyBuds/macOS hardware acceptance.
