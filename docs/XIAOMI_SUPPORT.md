# Xiaomi / Redmi 型号支持

本次新增 16 个精确型号配置。前 10 款接入 MMA 控制，后 6 款仅接入基础信息和电量。功能以型号配置及有效设备响应共同约束；这些配置尚未完成 HeyBuds/macOS 实机验收。

| 型号 | 传输 | 接入范围 |
| --- | --- | --- |
| Xiaomi Buds 5 Pro（蓝牙版） | BLE AF00 | 电量、降噪/通透、预设及十段自定义 EQ、手势、双连开关、佩戴检测、空间音频/头部跟踪、查找 |
| Redmi Buds 8 Pro | RFCOMM FD2D | 电量、降噪/通透、预设及十段自定义 EQ、手势、双连开关、佩戴检测、空间音频/头部跟踪、低延迟、查找 |
| Redmi Buds 8 Lite | RFCOMM | 电量、降噪/通透、预设及十段自定义 EQ、手势、双连开关、查找 |
| Redmi Buds 8 | RFCOMM | 电量、降噪/通透、预设及十段自定义 EQ、手势、双连开关、佩戴检测、查找 |
| Redmi Buds 8 Active | RFCOMM | 电量、预设及十段自定义 EQ、手势、双连开关、低延迟、查找；无 ANC |
| Redmi Buds 6 Pro | RFCOMM | 电量、降噪/通透、预设及十段自定义 EQ、手势、双连开关、佩戴检测、空间音频/头部跟踪、低延迟、查找 |
| Redmi Buds 6 Lite | RFCOMM | 电量、降噪/通透、预设及十段自定义 EQ、手势、低延迟；不提供双连、佩戴检测开关或查找 |
| Redmi Buds 6 Play | RFCOMM | 电量、预设 EQ、手势、低延迟、查找；无 ANC、自定义 EQ 或双连 |
| Redmi Buds 5 Pro | RFCOMM | 电量、降噪/通透、预设及十段自定义 EQ、手势、双连开关、佩戴检测、固定空间音频、低延迟、查找 |
| Redmi Buds 5 | RFCOMM | 电量、降噪/通透、预设 EQ、手势、双连开关、佩戴检测、低延迟、查找 |
| Xiaomi 耳夹式耳机 M2529E1 | BLE AF00 | 只读电量及可用固件信息 |
| Redmi Buds 6 | macOS 系统上报 | 只读电量及可用固件信息 |
| Redmi Buds 6 Active | macOS 系统上报 | 只读电量及可用固件信息 |
| Redmi Buds 4 Pro | macOS 系统上报 | 只读电量及可用固件信息 |
| Redmi Buds 3 | macOS 系统上报 | 只读电量及可用固件信息 |
| Mi True Wireless Earbuds Basic S / TWSEJ05LS | macOS 系统上报 | 只读电量及可用固件信息 |

“接入”表示实现的协议范围，不保证每个地区、固件都返回这些字段。未得到有效响应的控制隐藏或禁用。基础型号的降噪等硬件功能不因此被开放；系统没有上报电量时显示未知，不从 Windows HFP 报告推定 macOS 可读。

## 连接与功能边界

- 型号名与已知别名精确匹配，控制型号还核对设备上报的 Xiaomi VID/PID。新配置不能通过手动型号覆盖套给另一设备。Wi-Fi 版 Buds 5 Pro、6 Pro 电竞版及名字近似的未列型号不套用这些配置。旧的小米系列配置保持独立。
- RFCOMM 只查询明确的小米服务 UUID，并从其 SDP 记录取得通道；不复用源项目的固定通道，也不扫描端口。Buds 5 Pro 和耳夹只使用 AF00 / AF07 / AF08 BLE 控制特征。
- 需要认证的型号执行完整双向 50/51 认证；失败即结束会话。8 Pro 的 Mac C0 端点和 6 Lite 按各自公开协议采用直接读取。耳夹不发送会阻断其后续响应的认证命令。
- 8 Pro 使用公开 Mac 抓包对应的 C0/F2 降噪写入，保留本会话已读到的各模式强度；初次选择未观察过的模式采用已记录的第一个档位。此轮不新增强度或智能降噪界面。6 Lite 只以写入后新收到的模式通知确认降噪。
- 预设、空间音频、低延迟、双连和佩戴开关均需新回读确认。手势只提供该型号允许的动作，修改一耳时保留另一耳及未知记录。自定义 EQ 使用设备报告的范围，且仅在自定义预设已选中时编辑。
- 查找前重新读取佩戴状态，检测到任一耳佩戴时拒绝开始；响铃仅报告“请求已发送”。不提供 OTA、解除配对、任意命令或设备列表管理。
- 系统电量只读取当前已连接、地址一致的设备；只上报总电量时显示一项“耳机”，不虚构左右耳和盒电量，不读取未连接设备的历史条目。

## 来源与验收

主要来源为 [BudsLink](https://github.com/maniacx/BudsLink)、[MiBudsClient](https://github.com/CesurPolat/MiBudsClient)、[buds-ctl](https://github.com/LeoLee0812/buds-ctl)、[redmi-buds-bar](https://github.com/robin-liquidium/redmi-buds-bar) 和 [MiPods](https://github.com/JackWPP/MiPods)。固定版本、文件指纹及许可边界见 [Xiaomi 来源](licenses/Xiaomi.md) 和 [upstream-sources.json](upstream-sources.json)。

软件验证覆盖公开报文、独立认证向量、模拟设备会话及精确系统电量匹配。仍需逐型号验证服务发现、固件/地区差异、电量与充电标志、实际设置及手机同步、入盒重连和睡眠唤醒；上游的硬件报告不算 HeyBuds 的实机验收。

English: 16 explicit profiles, comprising 10 MMA control profiles and 6 read-only battery profiles. Capabilities are enabled only by model-specific evidence and valid responses. Hardware acceptance on HeyBuds/macOS remains pending.
