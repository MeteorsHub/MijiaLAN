# MijiaLAN · 米家局域网桥

**简体中文** · [English](README.en.md)

通过 Mac 菜单栏控制米家 Wi-Fi 设备，并把设备接入 Apple「家庭」。

MijiaLAN 使用 miIO / MIoT 协议直接与局域网设备通信。已有设备 token 时可手动添加，也可以用米家 App 扫码，一次性从小米云导入凭据。导入后的日常控制走局域网，Mac 同时充当 HomeKit 桥，让 iPhone、Apple Watch、HomePod 和 Siri 访问这些设备。

## 功能

- **控制中心式面板**：设备磁贴、电源开关、详情页和离线原因都在菜单栏里。左键显示或隐藏面板，右键打开退出菜单。
- **Apple 家庭桥接**：按设备类型提供灯、插座、风扇、空气净化器、空调及传感器服务，可单独选择要桥接的设备。
- **详细控制与共享状态**：Mac 与 HomeKit 共用能力目录、轮询和命令执行入口，支持机型对应的模式、亮度、色温、温度、风速、摆动、读数和厨房设备菜单。
- **本地凭据存储**：设备 token、设备清单和 HomeKit 配对信息保存在 macOS 钥匙串，不持久化小米云登录会话。
- **中英文界面**：跟随系统或单独 App 语言设置，支持系统、浅色和深色外观。
- **卷帘日常控制**：`dooya.motor.dc1545` 可按设备保存启用选择，提供实际位置、0–100% 目标、全开、全关和优先停止；HomeKit/Matter 控制单独验收。详见[功能边界与一次性验收清单](docs/curtain-daily-control.md)。
- **自动找回 IP**：定期广播发现设备，在 DHCP 地址变化后按设备 ID 更新地址。
- **后台性能优化**：离线重试逐步退避，最长间隔 24 小时；面板隐藏 30 秒后释放界面，并保留页面、滚动位置和输入草稿。详见[性能与后台运行说明](docs/performance.md)。

## 环境要求

- macOS 15 或更高版本。
- Apple Silicon 或 Intel Mac，发行包同时包含两种架构。
- Mac 与设备网络互通，并允许 App 访问「本地网络」；HomeKit 发现还需要 Bonjour / mDNS 可达。
- 扫码导入及获取尚未缓存的设备规格需要联网。

## 下载与安装

在 [GitHub Releases](https://github.com/iPocket-APP/MijiaLAN/releases/latest) 下载 `MijiaLAN-<版本号>-universal.dmg`，打开后将 `MijiaLAN.app` 拖入「应用程序」并启动。也提供 ZIP 包和 `SHA256SUMS.txt` 校验值。

正式发行包使用 Developer ID 签名、启用 Hardened Runtime，并经过 Apple 公证，App 与 DMG 均附有公证票据。macOS 询问「本地网络」权限时请选择允许。

## 构建与启动

源码构建需要提供 **Swift 6.4 或更高版本**的 Xcode / 命令行工具，首次下载 SwiftPM 依赖需要联网。

```bash
git clone https://github.com/iPocket-APP/MijiaLAN.git
cd MijiaLAN
./scripts/build_app.sh
open build/MijiaLAN.app
```

默认脚本会生成并临时签名 `build/MijiaLAN.app`，用于本机运行；自行构建不会自动进行 Apple 公证。正式发行打包流程见[发行说明](docs/releasing.md)。

## 使用

1. 打开菜单栏面板，进入设置。
2. 选择服务器地区，点击「扫码导入设备」，用手机的米家 App 扫码确认。已有凭据时，也可以手动填写设备 IP 和 32 位十六进制 token。
3. 在 HomeKit 设置里选择要放进「家庭」的设备。已经原生接入 HomeKit 的设备可取消桥接，避免重复。
4. 在 iPhone「家庭」中选择 **+ → 添加配件**，扫描桥的二维码。HomeKit 会提示这是未认证配件，确认后继续添加。

Mac 需要持续运行此 App。默认启用防止闲置休眠，可在设置中关闭；Mac 休眠、关机或 App 退出时，桥接设备可能显示「无响应」。家庭外的远程访问和自动化还需要 HomePod 或 Apple TV 等家居中枢。

设备重新配网可能改变 token，此时需要重新导入。云端未返回有效 token / IP，或固件未开放局域网接口的设备，无法仅凭设备名称实现控制。

## 设备支持与边界

当前内置以下 **10 个型号**的 MIoT 规格与能力适配。规格、协议映射和自动化测试并不代表所有固件都已完成实机控制验收。

| 类别 | 型号 |
| --- | --- |
| 插座 | `chuangmi.plug.m3`、`cuco.plug.v3` |
| 空气净化器 | `zhimi.airpurifier.rma1` |
| 台灯 | `yeelink.light.lamp4` |
| 空调伴侣 | `lumi.acpartner.mcn02` |
| 循环扇 | `dmaker.fan.p28` |
| 破壁料理机 | `chunmi.juicer.a1` |
| 养生壶 | `chunmi.health_pot.a1` |
| 空气炸锅 | `careli.fryer.maf07c` |
| 电饭煲 | `chunmi.cooker.cmwy3` |

蓝牙设备、Zigbee / 蓝牙 Mesh 网关子设备和云端灯组不在当前直接控制范围内。其他 Wi-Fi 型号是否可用，取决于有效凭据、固件的局域网支持和已有协议映射。

厨房设备选择菜单只设置待应用参数，仍需单独执行开始动作。没有确认参数语义的接口不会发送猜测命令。HomeKit 无适合原生控件的项目通过具名开关或预设表达，部分读数仅在 Mac 展示。空调的「当前温度」目前使用设定温度占位，不能当作实测室温。

逐项权限、参数和验证边界见 [设备接口矩阵](docs/device-interface-matrix-2026-10-31.md)。

## 隐私

MijiaLAN 没有自建云服务、广告或分析 SDK。扫码导入会连接小米服务；导入或手动添加时，规格服务可能访问 `miot-spec.org`。设备控制使用 UDP 54321，Apple「家庭」通过局域网 HAP 桥访问设备。

源码中的测试 token 和预览数据是示例。真实设备清单、钥匙串数据、配对码、诊断记录及本机截图不属于仓库发布内容。诊断导出虽然不包含 token 或配对密钥，仍可能含设备名称、ID、状态和时间，分享前需要检查。

完整数据流、命令行注意事项和本次开源检查范围见 [隐私说明](PRIVACY.md)。

## 开发

```bash
swift test
swift build --product mijia-lan
swift run mijia-lan discover
swift run mijia-lan matrix
```

CLI 还提供 `info`、`get`、`set`、`call`、`spec` 和从标准输入读取设备清单的 `status`。不带参数运行 `swift run mijia-lan` 可查看用法。`discover` 默认不打印 token；只有明确传入 `--show-tokens` 才输出旧固件可能暴露的 token。其他命令的 token 参数可能进入终端历史和进程参数，请优先使用 App 导入凭据。

构建 Debug App：`./scripts/build_app.sh debug`。构建后，可使用模拟设备直接运行 Debug 可执行文件：

```bash
MIJIALAN_UI_PREVIEW=1 "$(swift build --show-bin-path)/MijiaLANApp"
```

| 环境变量 | 用途 |
| --- | --- |
| `MIJIALAN_UI_PREVIEW=1` | 仅 Debug：使用模拟设备和内存凭据，关闭 HomeKit 桥及真实设备发现 |
| `MIJIALAN_EPHEMERAL=1` | 使用内存凭据及单独的偏好设置域，不读取真实钥匙串；仍可能发送网络请求 |
| `MIJIALAN_SEED_CONFIG=<path>` | 配合临时模式，从本地 JSON 载入测试设备；文件可能包含凭据 |
| `MIJIALAN_DIAGNOSTICS_OUTPUT=<path>` | 导出读数和错误；文件仍属于私密诊断数据 |
| `MIJIALAN_SNAPSHOT=<path>` | 渲染面板截图；可用 `MIJIALAN_SNAPSHOT_DELAY` 指定等待秒数 |
| `MIJIALAN_UI_THEME=dark/light` | 配合截图选择外观 |
| `MIJIALAN_UI_PAGE=<did>/settings` | 选择截图初始页面，默认首页 |
| `MIJIALAN_SNAPSHOT_WINDOW=<seconds>` | 打开原生交互预览窗口 |

| 目录 | 内容 |
| --- | --- |
| `Sources/MijiaLAN` | miIO 协议、发现、设备导入、凭据存储、能力目录和共享控制器 |
| `Sources/MijiaHomeKitBridge` | HomeKit 配件映射、桥接和配对状态 |
| `Sources/MijiaLANApp` | SwiftUI / AppKit 菜单栏界面 |
| `Sources/mijia-lan` | 命令行工具 |
| `Tests` | 协议、能力、安全边界、HomeKit 和本地化测试 |
| `Vendor/hap-swift` | 保留原协议的 HAP 实现及本地修复 |

## 协议与致谢

本项目的原创代码使用 [MIT License](LICENSE)，版权归 iPocket-APP。第三方组件保留各自许可证：

- [MenuBarMijia](https://github.com/jryang1997/MenuBarMijia) 的 `MijiaCore`（MIT）：扫码登录、MIoT 规格解析、设备合成和 HomeStore。
- [hap-swift](https://github.com/acumen-dev/hap-swift)（Apache-2.0）：HomeKit Accessory Protocol 实现，内置副本包含本地修复。
- Apple Swift 开源库及其他间接依赖：详见 [第三方声明](THIRD_PARTY_NOTICES.md)。

本项目为社区项目，与小米、米家或 Apple 无隶属关系，也未获得 HomeKit / MFi 认证。第三方协议、服务及商标的权利不由本项目的 MIT 许可证授予。

## Matter / Aqara 桥接

设置中新增与 HomeKit 并列的 Matter 桥接，可独立或同时启用，分别选择设备。
Matter 支持兼容灯的调光与色温、插座、风扇、部分净化器和传感器，提供配对二维码和运行状态。
两种桥接共用 App 的设备控制层。Apple「家庭」也支持 Matter。
构建与支持范围见 [MatterBridge/README.md](MatterBridge/README.md)。提交 `9060d6d` 已在本地 Mac 通过 CLI、App 编译和全部 Swift 测试；原生界面、完整打包签名和 M200 实机验收仍待完成。
