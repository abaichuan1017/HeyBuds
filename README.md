<div align="center">

<img src="docs/HeyBuds.png" alt="HeyBuds" width="112">

# HeyBuds

**你的耳机，随手可控。**

轻量、原生的 macOS 菜单栏耳机助手

[下载应用](https://github.com/abaichuan1017/HeyBuds/releases/latest) · [English](README_EN.md) · [完整型号清单](docs/SUPPORTED_DEVICES.md)

</div>

在菜单栏查看电量、切换降噪与通透、调整音效和管理多设备连接。支持中文和英文，采用原生界面，并通过 Sparkle 提供应用内更新。无遥测。

<table>
  <tr><th>未连接</th><th>连接弹窗</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/disconnected.jpg" alt="HeyBuds 未连接状态" width="300"></td>
    <td valign="top"><img src="docs/images/connection-popup.jpg" alt="HeyBuds 连接弹窗预览（示例电量）" width="300"></td>
  </tr>
  <tr><th>主面板</th><th>高级功能</th></tr>
  <tr>
    <td valign="top"><img src="docs/images/home.jpg" alt="HeyBuds 电量与降噪面板" width="300"></td>
    <td valign="top"><img src="docs/images/advanced.jpg" alt="HeyBuds 音效与高级功能" width="300"></td>
  </tr>
</table>

## 支持范围

| 品牌 | 已接入能力 |
| --- | --- |
| OPPO / OnePlus / realme | 电量、降噪、EQ、空间与游戏音效、多设备 |
| vivo / iQOO | 电量、降噪、EQ、空间与游戏音效、多设备 |
| HUAWEI | 电量、降噪、EQ、自定义 EQ、多设备 |
| Xiaomi / Redmi | 系列识别、电量；低延迟需有效状态回读 |
| EDIFIER | 支持 SPP 的系列电量及降噪 |

具体功能取决于型号、固件和设备响应。详见[型号清单](https://github.com/abaichuan1017/HeyBuds/blob/main/docs/SUPPORTED_DEVICES.md)与[兼容性说明](https://github.com/abaichuan1017/HeyBuds/blob/main/docs/COMPATIBILITY.md)。

## 安装与使用

需要 **Apple Silicon Mac、macOS 26+ 版本**。

1. 从 [Releases](https://github.com/abaichuan1017/HeyBuds/releases/latest) 下载 `HeyBuds-arm64.dmg`，打开后将 HeyBuds 拖入“应用程序”。
2. 在系统蓝牙设置中配对并连接耳机，退出其他耳机控制器。
3. 打开 HeyBuds 并允许蓝牙访问，点击菜单栏图标选择耳机。
4. 在主面板调节降噪，在“高级功能”调整音效；设置中可开启连接提示、低电量提醒、自动重连和登录时启动。

设置底部可查看版本、下载并安装更新。“请作者喝杯咖啡”可选择金额并显示对应收款码，请使用支付宝扫码。底栏依次提供项目名称与许可、GitHub、脱敏诊断和退出。

应用尚未公证。若 macOS 阻止打开，确认下载来源后，在“系统设置 → 隐私与安全性”选择“仍要打开”，参见 [Apple 说明](https://support.apple.com/zh-cn/102445)。

找不到耳机时，先确认系统蓝牙已连接，再从设备菜单选择“重新查找设备”。状态缺失时可点底部刷新；从 EncoBar 升级请先退出旧应用，偏好会自动迁移。

## 从源码构建

需要 Swift 6.4 和 macOS 27 SDK。

```sh
git clone https://github.com/abaichuan1017/HeyBuds.git
cd HeyBuds
swift test
bash scripts/build.sh
open dist/HeyBuds.app
```

输出为 `dist/HeyBuds.app` 和 `dist/HeyBuds-arm64.dmg`。发行构建只打包应用、运行资源与许可；开发工具、参考表和文档保留在源码中。

[贡献指南](CONTRIBUTING.md) · [架构](docs/ARCHITECTURE.md) · [验证记录](docs/VALIDATION.md) · [更新记录](CHANGELOG.md) · [反馈问题](https://github.com/abaichuan1017/HeyBuds/issues)

## 许可与致谢

采用 [GPL-3.0-or-later](LICENSE) 许可。协议与型号资料主要来自 [OppoPodsManager](https://github.com/Zhaoyi-ya/OppoPodsManager)，并参考 [Realme TWS Mac Controller](https://github.com/anikket-b/Realme-TWS-Mac-Controller)。完整署名见[第三方声明](THIRD_PARTY_NOTICES.md)。

HeyBuds 是独立社区项目，与所列品牌无隶属关系。
