# Nothing / CMF bounded protocol provenance

`Sources/HeyBudsProtocol/NothingProtocol.swift` and its tests are newly written under HeyBuds' GPL-3.0-or-later license; the full license is in [LICENSE](../../LICENSE). This is an independent implementation after source inspection, **not a claimed clean-room process**. No upstream implementation text, assets, application structure, CRC tables, serial numbers, Bluetooth addresses, or private captures were copied. Public, non-identifying packet bytes are included as protocol test facts with attribution.

The four supported candidates are Nothing Ear (a) (B162), Nothing Headphone (1) (B170), CMF Buds 2 (B179), and CMF Buds Pro 2 (B172). Names use an exact alias list; identity must independently resolve to the expected model code. This file records source evidence, not HeyBuds hardware compatibility.

## Transport and checksum boundaries

All four profiles use the dedicated RFCOMM service `AEAC4A03-DFF5-498F-843A-34487CF133EB`. `nikiomori/nothing-x-macos` explicitly uses this service in `BluetoothManager.swift`, and its README lists all four models (Headphone (1) is experimental). Resolve the channel from that exact SDP record. No fixed-channel fallback was imported.

`swift-nothing-ear` is a separate BLE implementation: `Device.swift` prefers FD90 but selects characteristics dynamically. The inspected sources do not establish fixed write/notify UUIDs for these four models. This implementation has **no BLE route**; its characteristic UUID properties are nil. A BLE service is not evidence that arbitrary writable/notifying characteristics are safe.

All transmitted frames have control `0160`, 16-bit little-endian command and length, one-byte operation ID, and CRC over header plus payload. CRC uses reflected polynomial A001, initial FFFF, no final XOR, and little-endian storage. The retained receive buffer is bounded to 1,034 bytes (1,024-byte payload limit).

| Profile | Receive CRC policy | Evidence and limitation |
| --- | --- | --- |
| B162 | Header plus payload, control 0160 | EarA RFCOMM parser plus Swift protocol reference. No universal firmware guarantee. |
| B170 | Header plus payload, control 0160 | Conservative source-level profile from the Swift whole-packet convention and niki RFCOMM route. No B170-specific complete, CRC-verified receive capture was found in these sources; real-device validation is pending. |
| B179 | Header plus payload, control 0160 | Complete battery and ANC RFCOMM packets in the ncr CMF Buds 2 capture, independently recomputed. |
| B172 | Payload only, control 0160 | openNothing's B172 documentation and packet facts, cross-checked against the Swift source's explicit CMF Pro 2 comment. CRC-free control 0100 is accepted only for E001/E003 events with sequence zero. |

There is no alternate-CRC fallback and no acceptance of a missing checksum merely because a callback ended. Unrecognised controls/commands are rejected. Payload-only CRC does **not** authenticate a response's command or operation ID; structural validation and request correlation remain necessary. Events and ACKs cannot confirm a write.

The Swift model tests echo operation ID 1; niki associates callbacks with byte 7. openNothing's correlation tests are simulated. These are evidence for the field and matching strategy, not a guarantee that every firmware echoes every ID. The caller must match both command and sequence, avoid reusing a sequence within a connection, retire timed-out requests, and reset the codec on reconnection.

## Bounded payload facts

- Battery: `C007 → 4007`; earbuds use a count and `(component, value)` pairs, with 2=left, 3=right, 4=case for B162/B179; bit 7 indicates charging. Headphone (1) has a Swift `[0,0,value]` fixture and a niki count=1/component=6 path. Zero percent is valid; values above 100, absent components, and malformed reports remain distinct.
- B172 case battery is intentionally unavailable: its Swift BLE fixture uses component 4, but openNothing's RFCOMM enum names component 5 and its actual captured reply contains only left/right. The RFCOMM profile safely ignores these two ambiguous case entries while retaining valid bud readings; it does not import either case mapping without model/transport-specific verification.
- Noise: `C01E → 401E`, write `F00F [1,mode,0]`. B172 READ requires `[3]`; the other profiles use an empty request payload. Modes are 1=high ANC, 2=medium, 3=low, 4=adaptive, 5=off, 7=transparency. B170 accepts only the sourced compact `[0,mode]` status. EarA and B179 additionally have `(kind,value,0)` groups; B172 uses these groups. Kind 1 holds mode and kind 2 holds ANC level. The B172 captured group order is reversed relative to the B179 example, so parsing cannot assume the first group's value is mode.
- Presets: B162/B170 use `C01F → 401F`, write `F010 [id,0]`. IDs 0/1/2/3 mean Balanced/Voice/More Treble/More Bass. B179/B172 use `C050 → 4050`, write `F01D [id,0]`: 0/1/2/3/4/5 mean Balanced/Rock/Electronic/Pop/Enhance Vocals/Classical. The four model fixtures support single-byte replies. The upstream generic parser's two-byte offset fallback was deliberately excluded. CMF listening-mode switching is still marked partial in the Swift model documentation; these command facts require real readback and hardware validation.
- B170 Advanced EQ can override the preset register. `C04C → 404C` supplies a one-byte 0/1 status. A caller must freshly observe off before and after a preset write. The API supplies no Advanced EQ write, custom EQ, spatial, multipoint, bass, gesture, OTA, reset, or unpair command.
- Firmware: `C042 → 4042`, bounded ASCII dotted numeric version with optional trailing zero padding. The **B179 EQ** gate requires four numeric components at least `1.0.1.50`. This threshold comes from the accepted focused plan and explicit integration requirement; it is a conservative gate, not a newly verified universal minimum from either Swift source. No firmware update is performed or implied. Basic battery/noise remain independent of this EQ gate.
- Identity: B172 uses `C01C → 401C` and exact known Bxxx text. Other profiles use `C006 → 4006` configuration records, extracting only a model code from type-4 SKU-bearing values; nothing returns or persists the original serial or address. Conflicting SKU records fail closed. The Swift SKU mappings and niki mappings conflict for newer models: niki's 84/85/86 → B179 mapping is not used. B179 99 comes from the Swift model fixture; 98 is independently associated with B179 by the ncr source capture. No identifying capture content was copied. Unknown SKU/color variants are intentionally unsupported until separately sourced.

## Source and license attribution

Thanks to bestK1ngArthur and SwiftNothingEar contributors; nikiomori, Daniel and the Nothing X macOS contributors; oneydef (EarA); Jacek Becela and the omarchy-headphones contributors; and Evergaster's openNothing protocol research. niki's README acknowledges Arunavo Ray's original project and Ear (web). That acknowledgement does not resolve the licensing of every historical dependency.

The two requested Swift projects carry GPL v3 license files. EarA explicitly declares GPL-3.0-or-later. ncr/omarchy-headphones carries MIT (Copyright (c) 2026 Jacek Becela); only protocol packet facts were used from that project. No upstream source code is vendored here; existing HeyBuds GPL text remains available at the root.

openNothing's README/pyproject declare MIT but the fixed snapshot lacks the linked independent LICENSE file. It was treated as **protocol facts only**, not as permission to copy implementation code. Its prose, test implementation and runtime code were not transplanted. The ear-web source is known to have an AGPL LICENSE / GPL README conflict in the research plan; **no ear-web code was read for this implementation or copied**. A permissive or GPL wrapper does not establish relicensing of AGPL or ambiguous upstream code. Numeric protocol facts and newly written control flow are not represented here as a license clearance for those projects.

## Fixed source fingerprints

SHA-256 below identifies the exact read-only snapshots consulted. Links are pinned to commits. Tests in the Swift source often omit CRC bytes, so they support payload layouts only; those truncated fixture envelopes were not adopted as acceptable incoming frames. New synthetic tests are labelled as such. These fingerprints do not establish a new hardware run.

### [bestK1ngArthur/swift-nothing-ear](https://github.com/bestK1ngArthur/swift-nothing-ear/tree/b56c15e5749996f8f0e4fda54622079ea395686a)

Commit: `b56c15e5749996f8f0e4fda54622079ea395686a`.

| File | SHA-256 |
| --- | --- |
| `LICENSE.md` | `5546ad8e1dd114ed3772a1b530d530593ef3eea748f91837120767944e22259b` |
| `Sources/SwiftNothingEar/Bluetooth.swift` | `347bf7dc5f9c1ff4feb9ca6a724bcc78c29b4ed93d8b393216c9d13d3adb6843` |
| `Sources/SwiftNothingEar/Device.swift` | `4f78bf60df9a8e9d3635721a5e08b6d09bfa184bc4df764927459fed6203885c` |
| `Sources/SwiftNothingEar/DeviceModel.swift` | `867c3264b48afdf66f7cc77810453ed355252eee89e0ca58f860db6728426a8c` |
| `Sources/SwiftNothingEar/DeviceCapability/EQ.swift` | `7ae9b806e7c4368f580c40f9fe3a1c7b76a2ec9f6518eb8ea128e60b56e2965f` |
| `Sources/SwiftNothingEar/DeviceCapability/NoiseCancellation.swift` | `0b7a37411d5f2b31ab88213c59ced5edda6a35a30625fa5fe43206b772b2e5ee` |
| `Tests/SwiftNothingEarTests/NothingEarATests.swift` | `c16ddc0991b7256a00ff63e0d1b9070fb5acc812cb6acacfe8610857e25cb78e` |
| `Tests/SwiftNothingEarTests/NothingHeadphone1Tests.swift` | `29774f907ce0d5b7813d010aeb521bd537f54eb5f5c6196cf7cc35fe3d789362` |
| `Tests/SwiftNothingEarTests/CMFBuds2Tests.swift` | `36b10bcb8d2f2bf9e00508843728539684e778782cf0b156ca7bb28328651f59` |
| `Tests/SwiftNothingEarTests/CMFBudsPro2Tests.swift` | `1357df6ec98dee18c04cc9eb92aee1a404675c2192290df7418a80720a798467` |
| `Docs/cmf_buds_2.md` | `6a27a90ddb9a53d9ea858e5656ac5a1e751d545179086bc08de22916de486e50` |

### [nikiomori/nothing-x-macos](https://github.com/nikiomori/nothing-x-macos/tree/ef55fc8650c699b80fbda56fdeda7ce2dccb1d2a)

Commit: `ef55fc8650c699b80fbda56fdeda7ce2dccb1d2a`.

| File | SHA-256 |
| --- | --- |
| `LICENSE` | `f817886ee6bb65ed3098a7987b1e9781653d15c71f85589ce0d2af663c66d373` |
| `README.md` | `723138efb89d1af59195914fb3b3c376fd70d4efc48301dec1cf51a96d8257b1` |
| `Nothing X MacOS/framework/BluetoothManager.swift` | `bf3c2dd4511d4ef3e3f03045154de0407b7cd1ea0c8a306f3de2610d1c78dd9f` |
| `Nothing X MacOS/framework/NothingServiceImpl.swift` | `c5d7ff1214412562d21f5a75805229089ff1bebc67563f7f40516185db373b7a` |
| `Nothing X MacOS/framework/utils/CRC16.swift` | `d7bbb5993514978ed5377d19b6eece1582c56651f59cb016d3aec3ff3001f13d` |
| `Nothing X MacOS/framework/utils/SKUUtil.swift` | `c8235c35c53d625fda8adfd85cea3245b69f5fb2b94dfe283ef564813a4a08f9` |
| `Nothing X MacOS/domain/enums/Commands.swift` | `c61efeb25167225894c23272be1796e9422d3d2cb7a2223b9acebec14ad1acdb` |
| `Nothing X MacOS/domain/enums/device/Codenames.swift` | `8c06591ea214d22d2b2764c2c55e9335c3e19ca12834d9e67686a08c7b472c78` |
| `Nothing X MacOS/domain/enums/device/SKU.swift` | `639a27e599f7a0368f6dca52c573379e477cde38d6464102b56c1c0ab0a9e5f9` |
| `Nothing X MacOS/domain/enums/device/EQProfiles.swift` | `89368c280433696e753a99292c15d46fb4aa33fbaa506a6683ddefff702f3cf0` |

### [Evergaster/openNothing](https://github.com/Evergaster/openNothing/tree/0a3ba1c9a8f72f60c3ed436a1340560aa80e4f66)

Commit: `0a3ba1c9a8f72f60c3ed436a1340560aa80e4f66`.

| File | SHA-256 |
| --- | --- |
| `README.md` | `e300aafa7df1870d3d610c5802d01a429f00f6faae40b9b6679d17b9a9543d6e` |
| `pyproject.toml` | `02735b874f8d3ab09576c85191c63fae5a83aaa33e8d96cade320da0f4e7ef78` |
| `opennothing/protocol/packet.py` | `5522853bc96c7141601afe4ef5c7ec2066f8bd9b4cce3a2e804726a0f95068e6` |
| `opennothing/protocol/constants.py` | `55846efed30a1cbaedf863eac4003d61dc1d866851d8262d518ba9a0c3a628ca` |
| `opennothing/protocol/codec.py` | `d49d1207e1ad4039089a05b49df9225f510fb78d92e1ef8bf4b1b5687a8440eb` |
| `opennothing/protocol/enums.py` | `d973b8bc23f7fe40aba31e887b942894d9a78fed93e37c4b9e8e88d13fb985b0` |
| `opennothing/protocol/models.py` | `e8f0cf71a3252e26a733747da62b1a30069ef9d28677af067823d48b4f50c31f` |
| `opennothing/device/cmf_pro_2.py` | `d6355c3f08ab5b11f5b48f940d542889da5739f39fe8638212daf5eb41d68b36` |
| `tests/protocol/test_golden.py` | `e6c0f3eb61eeef7544d64d05df31c05ae2de5ba458c9235065a8eb8d4f2688fa` |
| `tests/protocol/test_codec.py` | `03f616f7e55b043d86880800e0edb5323504ea1054eee8f4dd2f2b4dbf7f5b04` |
| `tests/test_session.py` | `63834de49f3578003877139769f8b1acf6376e6a6ec0939216a60d95913cfb93` |
| `opennothing/transport/fake.py` | `4bc1d3cc336b4284a7c099606c1a5f2f4b6148fb7e1327e3d4d08713a76c5d95` |

### [oneydef/EarA-linux](https://github.com/oneydef/EarA-linux/tree/d633863e4ebdc18771c37424f1b7a67e57c0435e)

Commit: `d633863e4ebdc18771c37424f1b7a67e57c0435e`.

| File | SHA-256 |
| --- | --- |
| `LICENSE` | `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` |
| `NOTICE` | `a1097b92eeb1317a10c1fbf308273d06dec54fb0df723769abf0a614a4e5fb36` |
| `eara/protocol.py` | `beddc710bba0969837879968748e0bc26258493b8d0d1c308e701a3aeb9dcb49` |
| `eara/session.py` | `fffd4415694aa6846e171c987b0e7209d5e49af856df8fb1b7fbba0ae68ec239` |
| `tests/test_protocol.py` | `13b17d80b2dcf55d7e5e97f50f1f529c7b36a2d157d093f4cde9debe9a3be8c5` |

### [ncr/omarchy-headphones](https://github.com/ncr/omarchy-headphones/tree/607d1c86492e6d94541f4c615efc90f3e8f67328)

Commit: `607d1c86492e6d94541f4c615efc90f3e8f67328`.

| File | SHA-256 |
| --- | --- |
| `LICENSE` | `cf04864900ff929e5e79a1c49b4634aba85901c165b6b813dee405eaa80fe967` |
| `README.md` | `4aadee6e08858fcb561e5e7adec6702177c6450b8932c0315095dd7d43fd48d7` |
| `docs/captures/nothing-cmf-buds-2.txt` | `f7b1960decf30f8ab6a09e6dc591455f92e91d904357d76d75ff14923bc88055` |
| `docs/CMF-REVIEW.md` | `5155382996ed98ffbeeb6ea907f058da7adc05da2f4ea89474bf9f7f65065e2c` |
