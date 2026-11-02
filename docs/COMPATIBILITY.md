# 兼容性与验证边界

## 品牌范围

| 后端 | 目录记录 | 实现范围 |
| --- | --- | --- |
| OPPO / OnePlus / realme | 138 个产品 ID：57 / 32 / 49 | RFCOMM / BLE、电量、降噪、EQ、空间与游戏音效、多设备 |
| vivo / iQOO | 43 个显示型号，保留 87 条原始配置与项目代号 | GAIA、电量、佩戴、固件、降噪、EQ、游戏、空间音频、查找、多设备 |
| HUAWEI / HONOR | 27 个型号路由及别名 | 华为 Legacy TLV 原有功能；荣耀三款沿用 FreeBuds 4i 配置 |
| Xiaomi / Redmi | 16 个精确型号及保留的 1 条系列规则 | 10 款按型号提供 MMA 控制，6 款仅基础信息/电量；旧系列后端独立保留 |
| EDIFIER | W820NB / W200BT / EDIFIER，共 3 条规则 | SPP 电量及降噪；纯 BLE 型号未接入 |
| Sony | 12 个型号 | MDR V1/V2、电量、降噪与设备允许的通透参数 |
| Samsung | 13 个型号 | 新旧两代帧、电量、按型号开放噪声模式与预设 EQ |
| Google | 2 个型号 | Maestro 电量、降噪、预设 EQ |
| Bose | 5 个型号 | BMAP 电量、按代际开放降噪或模式控制 |
| Nothing / CMF | 11 个型号 | 专用控制服务、型号核对、电量、噪声模式及预设 EQ |
| Soundcore | 7 个型号 | 型号独立布局、电量、降噪、预设/自定义 EQ，部分型号双连 |
| Sennheiser | 2 个型号 | GAIA、电量、降噪、EQ、佩戴、设备列表；写入受固件限制 |
| JBL | 3 个型号 | BLE / RACE 降噪，Wave Buds 2 电量 |

合计 283 条记录，包含产品 ID、显示型号和系列规则，不等于 283 款实机通过。新增 39 款的逐组功能和来源见[桌面项目扩展](DESKTOP_EXPANSION.md)，小米新增 16 款见[Xiaomi / Redmi 支持](XIAOMI_SUPPORT.md)。完整名称见[型号清单](SUPPORTED_DEVICES.md)；机器可读目录可运行 `swift run heybuds-probe catalog` 生成，不在文档中重复存储。

原始资源与指纹见[上游来源](UPSTREAM.md)。vivo 原表保留在 `docs/reference/VivoDeviceModels.json`，归一化目录保留所有 `sourceEntries`；华为能力来自 `HuaweiModels.cs`。导入工具为 `scripts/import-brand-models.py`。

Apple / Beats 由 macOS 原生管理，已从本应用移除。

## OPPO Enco X4

- 产品 ID `06EC10`，别名 `OPPO Enco Bohr`；配置来自 [EncoDeck](https://github.com/TIANLI0/EncoDeck)，具体提交与指纹见[上游来源](UPSTREAM.md)。
- 已接入关闭、通透、自适应及智能／深度／中度／轻度降噪、5 个 EQ 预设和 10 段自定义 EQ；既有空间、游戏音效及多设备功能按配置与有效回读开放。
- 自适应使用父级模式，不单独提供“更少／标准／更多噪音”档位。开启空间音频前，必须读到 Hi-Res 已关闭；可先在手机端关闭 Hi-Res 后刷新。
- 本次验证包含上游公开帧重放和模拟会话；未在 HeyBuds/macOS 上完成 X4 实机验收。EncoDeck 的 Windows 实机报告不等于本应用的实机结果。

## Sony

- 原有七款保留功能；新增 WH-1000XM6、WF-1000XM6、WF-C700N、WF-1000XM4、LinkBuds S（WF-LS900N）。
- WH-1000XM3/WH-1000XM4 使用 MDR V1；其他已列型号使用 V2，包括 WF-1000XM4。先核对服务、协议握手、型号与功能，再开放控制；不能手动覆盖成另一型号。RFCOMM 通道来自对应 SDP 服务。
- 支持电量、关闭/降噪/通透、语音聚焦。除 ULT WEAR 外支持 1–20 级通透强度；ULT 的该字段未确认，不显示强度控件。WF 分左右耳与盒，WH/ULT 使用单电池。
- EQ、DSEE、Speak-to-Chat、查找与多设备管理未接入。新旧型号均须分别完成 HeyBuds/macOS 实机验收。
- WF-C700N 只对已知修复固件 2.0.7 开放降噪写入，2.0.5 与其他/未知固件只读。XM6 在设备报告新格式时保留两字节自适应参数；所有降噪写入先读当前参数再写后回读。

## Samsung

Galaxy Buds2、Buds2 Pro、Buds4 Pro 保留原有功能。新增初代、Buds+、Live、Pro、FE、Buds3、Buds3 Pro、Buds3 FE、Core、Buds4；初代使用独立服务、FE/EE 帧和 EQ 编码。初代/Buds+ 没有 ANC，Live/Buds3/Buds4 没有通透；其他噪声模式依型号和有效响应开放。Buds4 Pro 保留自适应及 5 档降噪强度；Buds2/2 Pro 保留触控锁。较新型号共用状态字段不代表完整布局或实机通过；未确认的充电标志不作推断。自定义 EQ 和 OTA 未接入。

## Google

Pixel Buds Pro、Pixel Buds Pro 2 使用 Maestro/Pigweed 控制服务，接入左右耳/盒电量、关闭/降噪/通透和五组五段 EQ 预设。逻辑路由只用只读请求探测，读写由独立 RPC 调用编号匹配。Pro 2 自适应模式、任意自定义曲线、其他 Pixel 型号与 Fast Pair 功能暂不开放。

## Bose

QuietComfort 45、QuietComfort Ultra Headphones (2nd Gen)、QuietComfort Ultra Earbuds (2nd Gen) 接入 BMAP 电量、已有 Quiet/Aware 模式及有有效回读的降噪级别。模式从设备完整列表识别，不覆盖自定义模式配置；EQ 未接入。头戴使用专用 SDP 服务；Ultra Earbuds 2 使用已配对链路的安全 BLE 特征和分包格式，不自动修复配对或使用不安全特征。

Ultra Earbuds 2 的组件 1/2 左右映射在固定资料中不一致，因此显示“耳机电量 1/2”，充电盒单列。未知电量保持未知，不由是否入盒推断充电。其他代际或仅名字近似的 Bose 不套用此协议配置。

QC35、QC35 II 使用旧版产品 ID、电量和 ANC 寄存器，开放 ANC 开/关，不具备通透，也不套用 QC45 模式结构。厂商 BMAP 或 SPP 服务的通道均来自 SDP。

## Nothing / CMF

Nothing Ear (a)、Headphone (1)、CMF Buds 2、CMF Buds Pro 2 使用独立型号配置，接入电量及基础降噪/通透。预设 EQ 仅在该型号有明确映射且回读有效时开放；Headphone (1) 使用单电池。CRC 覆盖范围、消息类型及 EQ 范围按型号检查，不以通用 ACK 确认设置。高级 EQ、低延迟、空间音频和多设备控制尚未开放。CMF Buds Pro 2 的盒电量编号存在资料冲突，暂保持未知。

新增 Ear (1)、Ear (2)、Ear (2024)、Ear (stick)、CMF Buds、CMF Buds Pro、CMF Headphone Pro。通过只读 Fast Pair 产品 ID 核对型号后才打开控制服务；未列产品变体不连接。Ear (stick) 不开放降噪，Headphone Pro 使用单电池，高级 EQ 开启时不覆盖预设。来源与许可边界见 [Nothing 说明](licenses/Nothing.md)。

## Soundcore、Sennheiser、JBL 与 HONOR

新增品牌的型号、功能及固件限制统一列于[桌面项目扩展](DESKTOP_EXPANSION.md)。Soundcore 不覆盖开启中的 HearID/空间音频 EQ；MOMENTUM 5 只对 6.21.5 开放写入，设备列表只读；JBL 暂不开放 EQ，230NC/770NC 电量未知。HONOR 三款仅复用上游明确确认同协议的 FreeBuds 4i 配置，不推广到其他荣耀型号。

以上新增型号均为源码和模拟协议接入，未进行 HeyBuds/macOS 实机兼容性验收。既有品牌的型号资源和控制功能保持原实现。

## Xiaomi / Redmi

16 个明确型号及逐项能力见[小米支持范围](XIAOMI_SUPPORT.md)。控制型号使用独立 MMA 编解码、按型号选择认证和服务，并核对设备身份；基础型号不会开放猜测设置。8 Active / 6 Play 不提供 ANC。8 Pro 使用 Mac C0 端点的配置回读，6 Lite 使用新通知确认降噪；其他可读设置都必须新回读一致。系统未提供电量时保持未知，只有总电量时显示单项“耳机”。所有新增型号仍需 HeyBuds/macOS 实机验收。

## 功能限制

- 功能同时受型号、固件、能力位和有效设备响应约束。未知、缺失、过期与真实零值分别处理；未知型号不开放猜测控制。
- T500 Pro 使用 MIT 参考中的独立降噪映射。OPPO 现有短帧单帧负载最多 248 字节，不猜测扩展编码。
- vivo TWS 3e 的强制双连不提供开关；其他 vivo 型号没有使能状态回读时保留未知，不用设备列表推断开关。
- 华为标准 SPP 必须结合型号识别和有效响应，不使用猜测通道。未解释的 MBB 分片不作为设置状态。
- 小米配置字段仍需实机核对；通用 ACK 不视为设置成功。
- OTA、解除配对、健康测量、依赖手机服务及上游未开放的功能不属于当前范围。

## 证据与验收

源码适配代表已移植逻辑；协议测试代表解析器或模拟会话通过；实机通过必须有具体设备、操作和观察结果。三者不能互相替代。当前执行结果见[验证记录](VALIDATION.md)，原有 Air5 Pro 观察不扩展到其他型号或品牌。

实机验收需分别检查身份与电量、设置写后回读、手机同步、入盒重连、睡眠唤醒和真实多设备状态。查找耳机先摘下耳机，单个控制器独占会话。测试不自动解除配对，不访问 OTA，不替用户切换整机睡眠。
