# MijiaLAN → Matter → Aqara M200 原型

App 提供两种可独立或同时开启的桥接：

- **HomeKit · Apple「家庭」**：原有的 HAP 桥接，继续使用 `hap-swift`。
- **Matter · Aqara / Apple「家庭」**：由 matter.js 处理配对、安全会话、fabric、属性订阅和持久化。

两种桥接使用同一个 App `DeviceController`，共享参数校验、命令排队和状态回读。
Matter 子进程通过匿名管道请求操作，不接收米家 token，也不需要导出设备清单。
设备选择独立保存，支持只开一个桥或同时开启。Apple Home 本身也接受 Matter；
同一设备同时通过 HAP 与 Matter 加入 Apple Home 会产生重复配件。

## 在 App 中使用

使用 `scripts/build_app.sh` 构建完整 App。构建需要 npm、curl 和 macOS Swift 工具链。
脚本安装固定版本 matter.js，并打包 Node.js 22.22.0 的 Apple Silicon 与 Intel 运行时，
下载后校验 SHA-256，再签名运行时和 App。终端开发模式的 `swift run MijiaLANApp` 不包含这些资源。

1. 导入米家设备后，打开设置。
2. 根据需要启用 HomeKit、Matter 或两者。
3. 进入「管理 Matter 设备与配对」，选择需要发布的设备。
4. 在 Aqara Home 中添加 Matter 设备，选择 M200 并扫描页面二维码。
   Apple「家庭」等其他 Matter 平台也可扫描。首次配对后的其他平台，请通过已有控制器的 Matter 共享功能获取新配对码。

Matter 默认关闭，开启后会记住选择；App 自动管理子进程，退出或关闭桥接时停止它。
配对数据保存在 `~/Library/Application Support/MijiaLAN/Matter/`。
重新连接保留配对身份，禁止通过删除存储来排查一般离线问题。
**当前 Linux 云环境没有验证 macOS 编译、原生界面或 M200 实机配对；尚不能视为已验证的发布版本。**

## 设备和属性映射

| 类型 | 发布的能力 | 限制 |
|---|---|---|
| 灯 | 开关、亮度、色温 | 按米家规格逐项开放；暂不支持连续调光、渐变及 RGB |
| 插座 | 开关 | 不映射计量及厂商设置 |
| 风扇 | 开关、手动风速百分比 | 暂不映射自动模式、摇头 |
| 空气净化器 | 开关、手动风速 | 仅支持能进入 Favorite 模式并设置 favorite-level 的规格；风速控制会切换到该模式 |
| 温度、湿度 | 读数 | 转换为 Matter 百分之一单位 |
| 光照 | 读数 | 按 Matter 对数编码转换 |
| 人体、接触传感器 | 布尔读数 | 要求规格提供对应语义的布尔属性 |

传感器可作为同一米家设备下的额外 Matter 端点。缺失读数时发布为不可达。
空调、窗帘、门锁和厨电暂未适配；不会把未知设备伪装成插座。
支持 Matter 协议并不自动解决米家能力与 Matter 设备类型之间的语义差异。
底层仍仅能接入 MijiaLAN 能在局域网控制的设备，新增协议不会使 Zigbee/蓝牙子设备自动可用。
M200 对未认证开发网桥的接受程度需要实机确认。

## 命令行开发模式

需要 macOS 15+、Swift 6.1+（例如 Xcode 16.3+）、Node.js 22+ 和 npm。
Mac、米家 Wi-Fi 设备及 M200 应在互通的局域网，允许 mDNS、多播及 IPv6。
桥接使用 UDP 5540，mDNS 使用 UDP 5353。Mac 需要保持唤醒并持续运行两个进程。

1. 在仓库根目录编译命令行程序并安装依赖：

   ```sh
   swift build -c release --product mijia-lan --force-resolved-versions
   cd MatterBridge
   npm ci
   ```

2. 在 Mac 的私有目录准备 `devices.local.json`，内容采用项目已有的 `LocalHomeConfig` 格式。
   下面的 IP、ID 和 token 都是示例，需替换成自己的 Wi-Fi 设备参数：

   ```json
   {
     "devices": [
       {
         "did": "123",
         "name": "台灯",
         "model": "yeelink.light.lamp4",
         "host": "192.0.2.1",
         "token": "00000000000000000000000000000000"
       }
     ],
     "skipped": []
   }
   ```

   文件中包含米家 LAN 密钥，使用 `chmod 600 /absolute/path/devices.local.json` 限制权限。
   不需要把清单上传至云端。原型不会自动读取 App 的钥匙串。
   优先使用项目自带规格的 `yeelink.light.lamp4`、`chuangmi.plug.m3` 或 `cuco.plug.v3`。
   其他型号需要本机已缓存对应 MIoT 规格，并提供 `specType`。

3. 从 `MatterBridge` 目录启动（路径换成实际绝对路径；Swift 产物目录可用
   `swift build -c release --show-bin-path` 查询）：

   ```sh
   npm start -- /absolute/path/MijiaLAN/.build/release/mijia-lan /absolute/path/devices.local.json
   ```

4. 在 Aqara Home 中添加 Matter 设备，输入终端中的手动配对码，选择 M200 作为控制器。
   如 App 拒绝开发网桥，请记录 M200 固件、地区和 Aqara Home 版本；软件测试不能代替这一步。

`Ctrl-C` 会关闭网桥和 Swift 子进程。再次用同一目录启动即可复用配对信息。
清单变化后需要重启；不支持的设备会跳过，无可用灯或插座时拒绝启动。
映射范围见上表。命令行模式使用独立控制器，请先退出 App，避免并发控制。

## 配对与设备身份

`MatterBridge/.matter/` 保存随机生成的配对参数、Matter 身份及 fabric 密钥，已加入 Git 忽略。
不要删除或上传这个目录。移动程序时需要同时保留它；它目前固定在 `MatterBridge` 目录下。
首次创建的目录权限为 `0700`，新建文件受 `umask 077` 保护。
同一时间只运行一个实例，matter.js 会锁定存储目录。

每台米家设备用其 `did` 的哈希作为端点 ID；端点编号由 matter.js 持久化。
改名或调整清单顺序不会创建新身份。删除整个 `.matter` 目录会丢失配对，需先在控制器中移除旧桥再重新配对。
请勿通过删目录排查一般离线问题。

## 本机 IPC

Node 用参数数组启动 `mijia-lan matter-rpc <config-path>`，通过 stdin/stdout 交换 JSON 行，
没有额外 HTTP 或 TCP 控制端口。路径是进程参数，token 仅由 Swift 从本机文件读取。
stdout 仅包含 RPC 响应，诊断走 stderr。RPC 不输出 token、主机地址或完整设备清单配置。

```json
{"id":1,"method":"snapshot"}
{"id":1,"devices":[{"did":"123","name":"台灯","kind":"light","reachable":true,"on":false}]}
{"id":2,"method":"set","did":"123","on":true}
{"id":2,"devices":[{"did":"123","name":"台灯","kind":"light","reachable":true,"on":true}]}
```

不可用读数的 `on` 可以省略，此时 `reachable` 为 `false`；不把未知状态解释为关机。
错误响应为 `{"id":2,"error":"..."}`，Matter 命令失败，不提交成功状态。
写入必须通过 `DeviceController.execute` 且回读确认；LAN 轮询只更新 Matter 属性，不再次下发命令。
通信超时或子进程退出会停止桥接，避免将过期读数持续发布为在线。排查后重启即可。
单次 RPC 超时为 30 秒，首版适合用一两台设备验证。

## 验证

```sh
# Matter 端与管道 IPC 测试，可在 Linux 或 macOS 上运行
cd MatterBridge
npm ci
npm test

# Swift 端测试，需要 Mac；从仓库根目录运行
swift test --force-resolved-versions --filter "MatterRPCTests|MatterDevicePlanTests|MatterPlatformTests"
```

Matter 测试创建并启动真实 matter.js 服务端，用模拟设备控制进程验证回读、写入失败、
离线、轮询不回写，以及重启并调整顺序后保留编号。它们不验证真实米家设备或 M200。
Swift 测试检查设备映射、单位转换、桥接选项独立保存，以及 IPC 数据中不包含 LAN 密钥。
`.github/workflows/matter-bridge.yml` 分别在 Linux 和 macOS 上运行这两部分；需要推送后才会执行。

实机验收请依次确认：M200 接受配对并显示桥下设备；Aqara 开关控制生效；
米家端改变状态后同步回 Aqara；离线显示；Aqara 自动化执行；重启后无需重新配对。

matter.js 使用 Apache-2.0 许可。此原型使用开发 Vendor ID `0xfff1`，没有 Matter 产品认证。

## 云端开发，本地只验证

本地从远端拉取代码后，在干净的 checkout 中运行 `bash scripts/validate_macos.sh`。
脚本记录确切提交号，编译 CLI 和 App、运行全部 Swift 测试和 Matter 测试、打包并验证签名。
日志保存在 `/tmp/mijialan-validation.*`，不修改已跟踪的源码，也不执行 commit 或 push。
依赖、构建产物和日志都是本地验证输出。将错误日志带回云端后修复，再拉取下一次远端提交。
脚本通过不等于原生界面及 M200 实机验收通过。
