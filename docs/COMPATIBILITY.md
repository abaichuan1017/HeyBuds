# 兼容性与验证边界

## 品牌范围

| 后端 | 目录记录 | 实现范围 |
| --- | --- | --- |
| OPPO / OnePlus / realme | 138 个产品 ID：57 / 32 / 49 | RFCOMM / BLE、电量、降噪、EQ、空间与游戏音效、多设备 |
| vivo / iQOO | 43 个显示型号，保留 87 条原始配置与项目代号 | GAIA、电量、佩戴、固件、降噪、EQ、游戏、空间音频、查找、多设备 |
| HUAWEI | 24 个型号路由及别名 | Legacy TLV、电量、降噪、EQ、10 段自定义 EQ、游戏、多设备 |
| Xiaomi / Redmi | 1 条系列规则 | RCSP 电量；低延迟配置需有效状态回读 |
| EDIFIER | W820NB / W200BT / EDIFIER，共 3 条规则 | SPP 电量及降噪；纯 BLE 型号未接入 |
| Sony | WF-1000XM5 / WH-1000XM5 / WH-CH720N，共 3 个型号 | MDR V2 RFCOMM、电量、降噪、通透强度和语音聚焦；待实机验证 |

合计 212 条记录，包含产品 ID、显示型号和系列规则，不等于 212 款实机通过。完整名称见[型号清单](SUPPORTED_DEVICES.md)；机器可读目录可运行 `swift run heybuds-probe catalog` 生成，不在文档中重复存储。

原始资源与指纹见[上游来源](UPSTREAM.md)。vivo 原表保留在 `docs/reference/VivoDeviceModels.json`，归一化目录保留所有 `sourceEntries`；华为能力来自 `HuaweiModels.cs`。导入工具为 `scripts/import-brand-models.py`。

Apple / Beats 由 macOS 原生管理，已从本应用移除。

## OPPO Enco X4

- 产品 ID `06EC10`，别名 `OPPO Enco Bohr`；配置来自 [EncoDeck](https://github.com/TIANLI0/EncoDeck)，具体提交与指纹见[上游来源](UPSTREAM.md)。
- 已接入关闭、通透、自适应及智能／深度／中度／轻度降噪、5 个 EQ 预设和 10 段自定义 EQ；既有空间、游戏音效及多设备功能按配置与有效回读开放。
- 自适应使用父级模式，不单独提供“更少／标准／更多噪音”档位。开启空间音频前，必须读到 Hi-Res 已关闭；可先在手机端关闭 Hi-Res 后刷新。
- 本次验证包含上游公开帧重放和模拟会话；未在 HeyBuds/macOS 上完成 X4 实机验收。EncoDeck 的 Windows 实机报告不等于本应用的实机结果。

## Sony

- 原有 WF-1000XM5、WH-1000XM5、WH-CH720N 保留原功能；新增 WH-1000XM3、WH-1000XM4、WH-XB910N、ULT WEAR（WH-ULT900N）。
- XM3/XM4 使用 MDR V1；其他已列型号使用 V2。先核对服务、协议握手、型号与功能，再开放控制；不能手动覆盖成另一型号。RFCOMM 通道来自对应 SDP 服务。
- 支持电量、关闭/降噪/通透、语音聚焦。除 ULT WEAR 外支持 1–20 级通透强度；ULT 的该字段未确认，不显示强度控件。WF 分左右耳与盒，WH/ULT 使用单电池。
- EQ、DSEE、Speak-to-Chat、查找与多设备管理未接入。新旧型号均须分别完成 HeyBuds/macOS 实机验收。

## Samsung

Galaxy Buds2、Buds2 Pro、Buds4 Pro 接入现代 SPP 帧、电量、关闭/降噪/通透和六组 EQ 预设。Buds4 Pro 另含自适应模式及 5 档降噪强度；只有有效状态字段存在时才启用。Buds2/2 Pro 触控锁保留各手势原设置，并按状态版本处理通话手势。旧代协议、其他型号、自定义 EQ 和 OTA 不在范围内。充电标志缺少确认的型号不推断充电状态。

## Google

Pixel Buds Pro、Pixel Buds Pro 2 使用 Maestro/Pigweed 控制服务，接入左右耳/盒电量、关闭/降噪/通透和五组五段 EQ 预设。逻辑路由只用只读请求探测，读写由独立 RPC 调用编号匹配。Pro 2 自适应模式、任意自定义曲线、其他 Pixel 型号与 Fast Pair 功能暂不开放。

## Bose

QuietComfort 45、QuietComfort Ultra Headphones (2nd Gen)、QuietComfort Ultra Earbuds (2nd Gen) 接入 BMAP 电量、已有 Quiet/Aware 模式及有有效回读的降噪级别。模式从设备完整列表识别，不覆盖自定义模式配置；EQ 未接入。头戴使用专用 SDP 服务；Ultra Earbuds 2 使用已配对链路的安全 BLE 特征和分包格式，不自动修复配对或使用不安全特征。

Ultra Earbuds 2 的组件 1/2 左右映射在固定资料中不一致，因此显示“耳机电量 1/2”，充电盒单列。未知电量保持未知，不由是否入盒推断充电。其他代际或仅名字近似的 Bose 不套用此协议配置。

## Nothing / CMF

Nothing Ear (a)、Headphone (1)、CMF Buds 2、CMF Buds Pro 2 使用独立型号配置，接入电量及基础降噪/通透。预设 EQ 仅在该型号有明确映射且回读有效时开放；Headphone (1) 使用单电池。CRC 覆盖范围、消息类型及 EQ 范围按型号检查，不以通用 ACK 确认设置。高级 EQ、低延迟、空间音频和多设备控制尚未开放。CMF Buds Pro 2 的盒电量编号存在资料冲突，暂保持未知。

以上新增型号均为源码和模拟协议接入，未进行 HeyBuds/macOS 实机兼容性验收。既有品牌的型号资源和控制功能保持原实现。

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
