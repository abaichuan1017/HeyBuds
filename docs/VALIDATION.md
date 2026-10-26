# Validation

Protocol and session tests cover simulated device responses. Application checks cover presentation, preference migration and signed update delivery. See [Actions](https://github.com/abaichuan1017/HeyBuds/actions) for build status.

Enco Air5 Pro has historical read/write observations. X4 coverage uses public EncoDeck frames and simulated sessions; HeyBuds/macOS hardware acceptance is still pending. Catalog entries do not guarantee hardware compatibility.

Sony WF-1000XM5, WH-1000XM5 and WH-CH720N coverage uses framing/parser fixtures and simulated MDR V2 sessions. Hardware acceptance for each model remains pending.

Build and release instructions are in [RELEASING.md](RELEASING.md). Model and feature limits are in [COMPATIBILITY.md](COMPATIBILITY.md).

The 0.5 expansion adds model-specific parser and simulated-session coverage for Samsung, Google Maestro, Bose BMAP, Nothing/CMF and Sony MDR V1/V2 profiles. Cases include invalid/truncated fields, checksum failures, fresh readback, delayed write completion, cancellation and stale-session events. BLE tests exercise segmentation without starting CoreBluetooth discovery.

All 16 newly listed models still need hardware acceptance: proprietary service discovery, model/firmware identity, actual battery/charging reports, each exposed setting and phone synchronization, plus disconnect/reconnect and sleep/wake behavior. Bose Ultra Earbuds 2 left/right component mapping remains unresolved. Local simulation is not a hardware compatibility claim.
