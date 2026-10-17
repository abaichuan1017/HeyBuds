<div align="center">

<img src="docs/HeyBuds.png" alt="HeyBuds" width="112">

# HeyBuds

**你的耳机，随手可控。**

原生 macOS 菜单栏耳机管理工具 · Apple Silicon · SwiftUI

[下载 v0.3.0](https://github.com/abaichuan1017/HeyBuds/releases/tag/v0.3.0) · [English](README_EN.md) · [支持范围](docs/COMPATIBILITY.md) · [从源码构建](#从源码构建) · [更新记录](CHANGELOG.md)

</div>

HeyBuds 在菜单栏集中显示耳机电量、降噪、音效和多设备状态，支持 OPPO／OnePlus／realme、vivo／iQOO、华为、小米／Redmi、漫步者，以及只读的 AirPods／Beats 广播。界面使用 macOS 原生控件与 Liquid Glass，支持中文和英文。

当前版本 **0.3.0**，项目原名 EncoBar。协议与型号数据主要移植自 [OppoPodsManager](https://github.com/Zhaoyi-ya/OppoPodsManager)，保留上游署名与 GPL 许可。

## 功能

- 左耳、右耳、充电盒电量与充电状态；未知值与真实 0% 分别处理，头戴式等设备支持单电量布局。
- 按型号显示降噪、通透及降噪强度，保持紧凑的主面板。
- 按设备能力开放 EQ、自定义 EQ、空间音频、游戏音效、佩戴检测等。
- 多设备列表、连接／断开和支持的连接优先级操作。
- 菜单栏弹窗、连接提示、低电量提醒、后台运行、登录启动及退避重连。
- 设备状态以有效响应和写后回读为准；通用 ACK 不代表设置成功。
- 无网络遥测、无内置自更新、不读取系统配对密钥。

## 支持范围

| 品牌 | 目录来源 | 当前范围 |
| --- | --- | --- |
| OPPO / OnePlus / realme | 137 个产品 ID | RFCOMM／BLE、电量、降噪、音效、开关、多设备等 |
| vivo / iQOO | 43 个显示型号，87 条原始配置 | GAIA、电量、降噪、EQ、空间／游戏、佩戴、查找和多设备等 |
| HUAWEI | 24 个型号路由 | 电量、型号专属降噪、EQ、部分 10 段自定义及双设备等 |
| Xiaomi / Redmi | 品牌系列识别 | 电量、可选认证；低延迟配置需有效回读后开放 |
| EDIFIER | W820NB、W200BT、EDIFIER 系列规则 | SPP 电量与降噪；纯 BLE 型号尚未接入 |
| Apple / Beats | 18 个广播型号映射 | 明文 BLE 广播电量／充电／佩戴，只读 |

**目录导入不代表逐款实机兼容。** 226 条目录记录包含系列规则，不能等同于 226 款具体耳机。新增品牌目前完成源码与模拟协议验证；实际功能受型号、固件、macOS 可见服务和有效设备响应限制。AirPods 匿名或加密广播不会被误认成当前设备。详见 [兼容性](docs/COMPATIBILITY.md) 与[品牌移植记录](docs/ALL_BRANDS.md)。

## 安装与使用

要求 Apple Silicon Mac、**macOS 27 或更新版本**。当前不提供 Intel 构建。

1. 解压 `HeyBuds-arm64.zip`，将 `HeyBuds.app` 放入“应用程序”文件夹。
2. 先在 macOS 蓝牙设置中配对耳机，退出其他耳机控制器，再打开 HeyBuds。
3. 按系统提示允许蓝牙访问；需要低电量提醒时单独开启通知。
4. 点击菜单栏图标使用。设备型号默认自动识别，通常不需要手动覆盖。

本地交付采用 ad-hoc 签名，尚未公证。macOS 可能要求你通过系统“打开”操作确认。不要关闭系统安全保护。登录启动需要应用位于稳定路径。

从旧版升级时，请先退出 EncoBar。HeyBuds 首次启动只迁移已识别的本地偏好，不覆盖已有 HeyBuds 设置。新 Bundle ID 为 `local.heybuds.app`，蓝牙、通知和登录启动等系统授权需按新应用状态处理。

## 从源码构建

需要 **Swift 6.4、macOS 27 SDK、Apple Silicon**。可使用匹配版本的 Command Line Tools 或 Xcode；普通构建不需要外部参考仓库、Rust、.NET 或第三方 Swift 包。

```sh
swift test
bash scripts/build.sh
open dist/HeyBuds.app
```

产物为 `dist/HeyBuds.app` 与 `dist/HeyBuds-arm64.zip`。重复构建会将上一个应用保存在 `dist/backups/`。如有自己的签名身份，可设置 `HEYBUDS_SIGN_IDENTITY`；脚本不会申请证书、公证、安装或上传发布。

```sh
python3 scripts/package-source.py
```

生成白名单筛选的 `releases/HeyBuds-v0.3.0-source.zip`、文件清单及校验值，不打包本地偏好、诊断、缓存和历史备份。[发布说明](docs/RELEASING.md) 记录 GitHub 准备流程。仓库包含 macOS 构建／测试工作流；云端运行结果须以上传后的 Actions 为准。

## 诊断与开发

```sh
swift run heybuds-probe catalog
swift run heybuds-probe devices
swift run heybuds-probe read
swift run heybuds-probe read --ble
```

硬件 probe 会占用设备控制通道：先退出 HeyBuds 和其他控制器，终端需获蓝牙授权。`--ble` 仅用于 OPPO 系 GATT。应用设置页提供默认移除设备地址、主机名和原始负载的诊断导出；提交问题前仍应检查内容。

项目分为 `HeyBudsProtocol`（帧、状态和型号）、`HeyBudsBluetooth`（传输和会话）、`HeyBuds`（SwiftUI 与系统集成）和 `heybuds-probe`（只读工具）。参见[架构](docs/ARCHITECTURE.md)、[贡献指南](CONTRIBUTING.md)及[验证记录](docs/VALIDATION.md)。

## 许可与致谢

**GPL-3.0-or-later**，完整许可见 [LICENSE](LICENSE)。基于 OppoPodsManager 的协议和型号资料，并参考 MIT 许可的 [Realme TWS Mac Controller](https://github.com/anikket-b/Realme-TWS-Mac-Controller)。Buds for macOS 仅作界面参考，没有复制其 PolyForm 许可源码或资源。

第三方署名与系统图标说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，来源文件指纹见 [UPSTREAM.md](docs/UPSTREAM.md)。HeyBuds 为独立社区项目，与所列耳机品牌及 Apple 无隶属关系。
