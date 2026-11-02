# Windows / Linux 参考项目的型号扩展

当前新增 39 个型号配置，目录由 228 条增至 267 条。以下是 HeyBuds 已接入的功能范围，**均未完成对应型号的 macOS 真机验收**。上游功能和上游实机记录不能代替本应用的验收；未列功能不因同品牌或同协议而自动开放。

| 品牌与新增型号 | 已接入 | 限制与待核验项 |
| --- | --- | --- |
| Soundcore：Life Q30、Life Q35、Space Q45、Space One Pro、Liberty 4 NC、Liberty 4 Pro、Liberty 5 | 型号独立电量与降噪布局、预设 EQ、8 段自定义 EQ；后五款双连开关 | HearID 开启时不覆盖 EQ；Liberty 4 Pro 空间音频开启时不改 EQ。按键、佩戴、设备列表和其他高级音效未接入；Q30/Q35 不推断双连开关 |
| Sennheiser：MOMENTUM 4、MOMENTUM 5 | 型号/固件核对、电量、降噪/通透、音效模式、按设备频点与范围编辑 EQ、佩戴检测、已配对设备列表 | M5 只允许固件 **6.21.5** 写入，其他固件只读；M4 可连接列表中的其他设备，M5 列表只读。不提供断开/解除配对命令；音效个性化开启时不覆盖 EQ |
| JBL：TUNE230NC TWS、Wave Buds 2、Tune 770NC | 降噪/环境声/关闭；Wave Buds 2 另有耳机及盒电量、固件 | 两款耳塞使用专用 BLE 控制端点；770NC 使用独立 RACE 协议。230NC/770NC 暂无电量来源；TalkThru 不冒充环境声；Wave EQ 的上游截断回包问题尚未解决，因此未开放 EQ |
| HONOR：Earbuds 2、Earbuds 2 SE、Earbuds 2 Lite | 荣耀名称路由，复用 FreeBuds 4i 的电量、降噪/通透和佩戴配置 | 依据 OpenFreebuds 明确的同协议说明；需要分别确认实际响应与功能，不扩展到其他荣耀型号 |
| Sony：WH-1000XM6、WF-1000XM6、WF-C700N、WF-1000XM4、LinkBuds S | 电量、降噪/通透、设备报告的通透参数；XM6 支持新增自适应参数格式且写入保留原值 | 功能仍依赖握手与功能列表。C700N 仅 **2.0.7** 开放降噪写入；2.0.5 及未知固件只读。EQ 未接入；不同型号上游证据强弱不同 |
| Samsung：Galaxy Buds、Buds+、Live、Pro、FE、Buds3、Buds3 Pro、Buds3 FE、Core、Buds4 | 电量、型号实际具有的降噪/环境声模式、预设 EQ；初代独立帧头、服务和 EQ 编码 | 初代及 Buds+ 不显示 ANC；Live、Buds3、Buds4 不显示通透。Buds3 FE/Core/4 采用上游共用字段，较新状态布局仍有待确认；不把整个配置目录称为实测通过 |
| Bose：QC35、QC35 II | 产品 ID 核对、单电池电量、ANC 开/关 | **没有通透**。使用旧版噪声寄存器，不套用 QC45 模式结构；上游强弱档位标注有差异，界面不提供高/低强度 |
| Nothing / CMF：Ear (1)、Ear (2)、Ear (2024)、Ear (stick)、CMF Buds、CMF Buds Pro、CMF Headphone Pro | 产品 ID 核对、电量、基础降噪与预设 EQ；Headphone Pro 单电池 | Ear (stick) 不开放降噪；高级 EQ 开启时不切预设。新型号先读取 Fast Pair 产品 ID，关闭该服务后打开独立控制服务；未识别产品变体停止连接。无自定义 EQ、按键或多设备写入 |

## 传输与确认

- Soundcore 在已识别型号上优先选择匹配厂商 UUID 掩码的 SDP 服务，再使用标准 SPP；通用串口服务不单独识别品牌。
- QC35 的 BMAP 或 SPP 通道取自 SDP；Samsung 初代使用自己的服务和 FE/EE 帧，不与现代 FD/DD 帧混用。
- Tune 770NC 的通道 21 来自该型号的明确上游实现，不是扫描或猜测候选；只给精确型号路由使用，必须先收到合法 RACE 状态才能开放写入。其他型号不能使用此通道规则。
- Nothing 的 Fast Pair 通道仅接收标准产品 ID 事件，不向它发送控制命令。产品 ID 不标识某一台物理设备；序列号和设备地址不进入产品配置或测试数据。
- 可写设置必须有新的读取确认；ACK、缓存或界面先行更新都不能确认成功。没有事务编号的协议无法从格式上完全区分延迟响应和同类通知，仍需真机确认手机同步及重连行为。

## 参考来源与许可

协议参考固定到下列提交，所读文件的 SHA-256 见 [upstream-sources.json](upstream-sources.json)。

| 项目 | 固定版本 | 用途 |
| --- | --- | --- |
| [OpenSCQ30](https://github.com/Oppzippy/OpenSCQ30/tree/200d9e1657dff67d516ed1b6347f312d7a1b01a7) | `200d9e16` | 逐型号状态、EQ 曲线、编码和服务选择；GPL-3.0-or-later |
| [momentum4-control](https://github.com/Ariazonaa/momentum4-control/tree/17aeea90ce12ffbb4521df1832b22de0bc08c666) | `17aeea90` | GAIA 命令、身份、固件与功能门控；MIT |
| [Omaphones](https://github.com/ncr/omarchy-headphones/tree/607d1c86492e6d94541f4c615efc90f3e8f67328) | `607d1c86` | JBL、QC35、CMF 型号协议记录；MIT |
| [JBL Control](https://github.com/AhmadRun/jbl-control/tree/a276b8561c15fc5a3effa76cb75500847219d750) | `a276b856` | Wave Buds 2 BLE、状态 TLV 与 EQ 限制；MIT |
| [770NC Windows Controller](https://github.com/Xeo23/JBL-Tune-770NC-Windows-Controller/tree/653f75af8b45071011995fce2d2a623b4de4f128) | `653f75af` | 770NC RACE 和明确的型号通道；MIT |
| [OpenFreebuds](https://github.com/melianmiko/OpenFreebuds/tree/0b4f14c0b500d491f0fb4ea38f2984ec334e3649) | `0b4f14c0` | 荣耀三款与 FreeBuds 4i 同协议说明；GPL-3.0 |
| [SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient/tree/68dfced0403b38114b77f2b374e606ce12a206a8) | `68dfced0` | MDR V2 新型号与参数；MIT |
| [Sound Connect](https://github.com/aecca/sound-connect/tree/749e54438ec7be055a45021fea30dff87de22975) | `749e5443` | Sony 与 QC35 II 配置交叉核对；MIT |
| [GalaxyBudsClient](https://github.com/timschneeb/GalaxyBudsClient/tree/754b6fdfb1c151b022cece775c8aaad4eb185afa) | `754b6fdf` | 型号规格、初代帧、状态字段和 EQ；GPL-3.0 |
| [ear-web](https://github.com/radiance-project/ear-web/tree/d076e1371572fbf0a14b441f9b3cafbf9a237e04) | `d076e137` | 产品 ID 与命令事实；LICENSE 为 AGPL，README 称 GPL，冲突未解决 |

ear-web 只用于互操作协议事实核对；未复制其实现代码、资源、CRC 表或应用结构，也不宣称其许可已厘清或本次是净室实现。Nothing 细节见 [来源说明](licenses/Nothing.md)。Fast Pair 消息结构另依据 [Google 官方规范](https://developers.google.com/nearby/fast-pair/specifications/extensions/messagestream)。其他采用或改写的 GPL/MIT 内容保留于 [第三方声明](../THIRD_PARTY_NOTICES.md) 与 `Licenses/`。
