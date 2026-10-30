# MijiaLAN · 米家局域网桥

一个 macOS 菜单栏 App：通过局域网（miIO / MiOT 协议，UDP 54321）直接控制米家 Wi-Fi 设备，
并把这些设备以 HomeKit 桥（HAP）的形式提供给 Apple「家庭」，让 iPhone、Apple Watch、HomePod 和 Siri 都能控制。

- **只登录一次**：米家 Wi-Fi 设备的局域网 token 只能从米家云读出。扫码登录后，App 读一次设备列表（token、局域网 IP、房间），
  随即丢弃登录状态（不保存 serviceToken），之后的控制完全走局域网。
- **也可以不登录**：已有 token（其他工具导出、旧备份）时，可以直接填 IP + token 添加设备。
- **秘密只放钥匙串**：设备 token 和 HomeKit 配对信息存放在同一个钥匙串项目里。

## 使用

```bash
scripts/build_app.sh
open build/MijiaLAN.app
```

1. 第一次运行时，macOS 会询问是否允许访问「本地网络」，请选「允许」（局域网控制和 HomeKit 都需要这个权限）。
2. 在菜单栏面板里选择服务器地区，点「扫码导入设备」，然后用手机「米家」App 扫码确认。
3. 导入完成后，HomeKit 部分会出现配对二维码和配对码。用 iPhone「家庭」App 依次点 **+ → 添加配件** 扫码；
   如果提示「未认证配件」，选「仍然添加」。
   本身已接入 HomeKit 的设备（比如米家台灯 1S），先在面板的「放进「家庭」的设备」里关掉，免得在「家庭」里出现两次。

Mac 和 iPhone 需要连在同一个 Wi-Fi 上。不在家时要远程控制或运行自动化，还需要一台家居中枢（HomePod 或 Apple TV）。
Mac 休眠后，「家庭」里的设备会显示「无响应」，所以默认会保持 Mac 不进入闲置休眠（可以在面板里关掉）。

## 能控制哪些设备

能控制的是**米家 Wi-Fi 设备**，也就是导入时云端给出了 token 和局域网 IP 的设备。下面几类不行，面板里会列出原因：

| 设备 | 原因 |
| --- | --- |
| 蓝牙设备（温湿度计、门锁等） | 不在 IP 网络上 |
| Zigbee / 蓝牙 Mesh 子设备 | 要经过网关；网关本身是 Wi-Fi 设备，可以导入 |
| 云端灯组 | 由云端合成，没有对应的实体设备 |

HomeKit 里目前能显示：灯（开关、亮度、色温）、插座、风扇、空调 / 暖气（模式、温度）和温湿度传感器。
设备规格（MIoT spec）在导入时从 miot-spec.org 下载一次并缓存（不需要账号），之后启动不需要联网。

设备重新配网后 token 会变，面板里该设备会显示橙色「token 多半不对」，重新扫码导入一次即可。
如果 DHCP 给设备换了 IP，App 每 5 分钟会广播扫描一次，按设备 ID 自动找回新 IP。

## 结构

| 目录 | 内容 |
| --- | --- |
| `Sources/MijiaLAN` | miIO 协议（包头、AES-128-CBC、握手和时间戳）、广播发现、`LANMiotAPI`（纯局域网实现的 `MiCloudAPI`）、云端一次性导入、手动添加、钥匙串 |
| `Sources/MijiaHomeKitBridge` | 设备到 HAP 配件的映射、HomeKit 桥控制器（基于 [hap-swift](https://github.com/acumen-dev/hap-swift)） |
| `Sources/MijiaLANApp` | 菜单栏 App |
| `Sources/mijia-lan` | 命令行调试工具：`discover`、`info`、`get`、`set`、`call`、`spec` |

MiOT 规格解析、设备合成、命令映射、扫码登录和 `HomeStore`（乐观更新、回滚）直接复用
[MenuBarMijia](https://github.com/jryang1997/MenuBarMijia) 的 `MijiaCore`（MIT），通过 SwiftPM 按提交固定版本。
`LANMiotAPI` 实现了它的 `MiCloudAPI` 接口，所以 `MiCloudProvider` 的轮询、规格加载和命令映射不用改就能跑在局域网上。

## 开发

```bash
swift test
swift build --product mijia-lan && .build/out/Products/Debug/mijia-lan discover
```

协议实现和 python-miio（Home Assistant 使用的实现）交叉验证过：测试里有一组 python-miio 生成的字节级测试向量。

开发用环境变量（直接运行 `MijiaLANApp` 可执行文件时使用）：

| 变量 | 作用 |
| --- | --- |
| `MIJIALAN_EPHEMERAL=1` | 秘密只放内存，使用单独的 defaults，不读写钥匙串，也不影响真实的配对 |
| `MIJIALAN_SEED_CONFIG=<json>` | 配合上一项，从 JSON 文件载入设备清单 |
| `MIJIALAN_SNAPSHOT=<png>` | 若干秒后（`MIJIALAN_SNAPSHOT_DELAY`，默认 6 秒）把面板渲染成 PNG |

HomeKit Accessory Protocol 采用 Apple 的非商业版规范，仅供个人使用，「家庭」App 会把桥显示为未认证配件。
