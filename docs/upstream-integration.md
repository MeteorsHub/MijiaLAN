# 上游功能选择性引入

对照来源：`iPocket-APP/MijiaLAN` 的 `main`，固定在 `28d6c43495a5da520fa057406f5c83a9ceb2a504`。本项目从 `7218166` 开始选择性引入，不把上游整条发布分支直接合并。后续可继续用 `git fetch upstream`、比较提交及独立功能分支维护。

## 引入范围

| 功能 | 上游依据 | 本项目结果 |
| --- | --- | --- |
| 恢复可重复构建 | `4615651` | 内置原 MijiaCore 1.1.4 的完整库源码、测试、资源及 MIT 许可；不再访问已删除的 MenuBarMijia 仓库 |
| HomeKit 数据约束和更多设备能力 | `35bc600`、`ab24c03`、`221a4d2`、`08c559f` | 约束数值、枚举及字符串长度，增加取暖、除湿、浴霸、扫地机和有明确配置的旧 miIO 设备映射；空气净化器可依据 PM2.5 报告空气质量 |
| HomeKit 可靠性 | `30a731c`、`d01c0f1`、`f3a41db`、`2104d0e` | 串行提交加密帧、按序推送事件，先回应控制请求再发送相关事件；保留混合读取中的成功状态，减少亮度写入及状态确认的额外等待 |
| 菜单栏与普通设备面板 | `a56d52f` | 数值转换不因异常设备回复崩溃，慢设备不阻塞其他已完成读数的发布；菜单栏图标缺失和面板越界时有定位回退 |
| 按服务选择 Apple Home 展示项目 | `5aedfd7`、`22552e1` | 可单独隐藏控件和传感器；保留其他服务的标识符，智能插座高级设置折叠；提示 HomeKit 的服务数量上限 |
| 登录时启动 | `0249821` | 设置中使用 macOS `SMAppService`，由用户主动选择，反映系统批准状态 |
| HomeKit 诊断摘要 | `7850dbc` 的功能方向 | 用本项目自己的缓存导出实现：仅含本地设备代号、型号、规格、读数类型和错误码；不查询设备、不导出原始值、不上传 |

设备映射只提供库支持的协议能力，不表示每台真实设备都已验收。没有合适标准服务的一次性动作不伪装成普通可重试电源开关。

## 保留的本项目行为

- Matter 与 HomeKit 继续共享 App 状态，读取桥接缓存不额外启动一轮米家查询。
- 普通轮询默认前台 5 秒、后台 30 秒，可设置并保留已有自定义值；慢轮次不重叠、不积压补发。刷新仍不覆盖未提交文字或打断滑块手势。
- `dooya.motor.dc1545` 继续使用独立串行驱动，正常完整读取为 `[2,3,4,9,10]`，所有产品能力和正常读写入口排除 `2.5`。不恢复已删除的卷帘启用门槛或 App 隔离长测模式；本轮不扩大卷帘的桥接控制范围。
- 保留严格的读取类型和枚举验证，不套用上游的通用数值到布尔转换；保留凭据存储、配对权限、会话撤销、HTTP 长度/连接/超时约束。
- 保留稳定 UDP 会话、校时策略、写入不盲重试以及 64 MiB 脱敏通信日志。未引入上游原始 miIO/HAP 报文输出功能。
- HomeKit 服务选择保存在已有偏好系统中，不清除设备、账号或配对。取消某项只影响该服务，重新显示仍使用原来的服务/特征标识符。

上游在 macOS 13 迁移中更改的 Combine/Observation 模型没有整体覆盖本项目；本项目仍要求 macOS 15，并使用原有 Observation 模型连接桥接同步。

## 暂不引入

- Sparkle、共享更新源、自动签名发布和上游版本号：这些涉及本项目自己的更新域名、签名和发布凭据，不能直接使用上游配置。
- macOS 13 兼容迁移：涉及整套 UI 观察和系统 API 回退，需单独验收。
- Apple TV/Rust 更新服务：不是当前原生 App 的运行能力。

## 依赖与构建

MijiaCore 的原始版本及 revision 见 `Vendor/MenuBarMijia/README.md`；48 个库源码文件未修改。新旧协议映射数据分别保留 Apache 2.0/MIT 许可与来源。打包脚本将所有 Vendor 许可纳入 App。

`Package.resolved` 已按 Swift 6.1 工具链重新解析并固定；`swift-collections` 为 1.6.0，`swift-log` 为 1.15.1，避免选择要求更新 Swift 的版本。仍使用 `--force-resolved-versions` 构建，不在 CI 中临时重写依赖。

```bash
swift build --product mijia-lan --force-resolved-versions
swift build --product MijiaLANApp --force-resolved-versions
swift test --force-resolved-versions
swift test --package-path Vendor/MenuBarMijia --scratch-path .build/mijiacore-tests
NODE_ENV=test npm --prefix MatterBridge test
bash scripts/build_app.sh debug
```

CI 会编译真实 App/CLI，并运行 SDK、HomeKit、Matter RPC、卷帘交互及新服务选择/诊断摘要回归；MijiaCore 另有定向回归。旧的 AppKit 面板动画测试在本地锁屏环境有已知失败，本轮没有改写窗口动画或用定时等待掩盖它。

## 验证边界

Linux 隔离回归 212 项通过：原有 SDK/交互回归及新数值/扫地机回归 152 项，HomeKit 映射、服务选择、值约束、帧顺序、写入来源、鉴权、接口报告及 Observation 回归 60 项。包含真实 UDP 回环、512 轮卷帘正常路径无 PIID5、写入去重和日志滚动。HomeKit 使用真实 HAPTransport/Swift Crypto，Linux 测试仅适配系统锁及 CryptoKit 模块名；miIO harness 的加密替身不等于 macOS 原生 AES/完整 App 验收。HAPTransport 亦已通过独立实际编译。Matter 的 GitHub job 已通过；原生 macOS CI 结果以本分支最终提交的 Actions 为准。

本轮没有部署 App、发布 Release 或联系家庭设备。原生界面、登录启动的系统授权状态、实际 HomeKit 配对/控制和长时间实机稳定性需在对应环境验收。正在运行的家庭旁读观察不受本分支影响。

### 本地首轮编译反馈后的修正

家庭 Mac 在 `0efbfa3` 上报告 MijiaCore 独立测试 313 项通过，但主 App/CLI 编译被 `DeviceInterfaceReport` 的旧 API 引用阻塞，其余 Swift 测试未执行。报告生成器现按 `Property.write` 的全部转换类型生成旧 miIO 参数，识别状态聚合读取和 cleaning 绑定，删除已退役的 `format`/`adjust` 引用。新增报告回归，并将真实报告文件纳入 Linux 检查，不再只检查两份 mapper。

Matter IPC 测试现显式选择临时 UDP 端口，并在 5540 已被占用时验证正常 ready/退出。生产默认 5540 保留；不需停止家庭正式桥接。本次修正不涉及设备协议、轮询或控制调度。完整 macOS 构建、测试和打包需在修正提交上重新验证。

### HomeStore 的 Observation 适配

家庭 Mac 在 `5afe00a` 上确认 Node 22.22.0 的 Matter 测试 8/8 通过（正式 5540 桥接未停），MijiaCore 独立测试 313 项通过；主编译随后被 `HomeStore` 上不存在的 Combine 投影阻塞，App/CLI 原生测试和打包尚未执行。桥接现在直接跟踪 `@Observable` 的 HomeStore 与 DeviceController，不修改内置核心库。

Observation 在 MainActor setter 中登记待处理工作，待赋值完成后读取当前缓存并重新注册；一批连续变化合并通知。重新绑定、关闭和重启会更新观察代次并取消旧通知，`waitUntilIdle` 同时等待观察通知与桥接同步。新增 5 项可离线运行的观察回归，以及一项桥接关闭/重启后仍只读缓存的原生集成回归；后者需在 Mac 编译完成后执行。设备协议、轮询、控制及配对存储保持原有实现。

### 同值写入的 ACK 与事件语义

家庭 Mac 在 `dbec688` 上完成原生 App/CLI 编译，主测试 341 项中 340 项通过（包括原面板动画、新服务选择、缓存诊断、Observation 和线级 HomeKit 回环），核心库另有 313 项通过。唯一失败来自旧的同值强制 EVENT 预期。当前适配器会执行控制并确认回读，HAP PUT 成功返回 204；确认值未变时不需要额外值变化事件。值变化、错误恢复和修正仍按已有规则通知订阅者。

此次仅更新测试：保留无来源连接的直接写入路径，并增加经鉴权的 PUT 路径；检查既有风扇方案的速度/电源各写一次且各自回读、GET 只读缓存，以及后续外部变化通知原写入者与另一订阅者。用独立订阅者的 FIFO 初始快照作为完成标记，先排除订阅初始事件，再证明无重复 EVENT，不依赖等待一段时间来推断无事件。HAP 协议层同值/后续变化回归已在 Linux 真实 HAPTransport/Swift Crypto 下通过；完整原生适配器用例仍需本地复验。生产源代码、ACK-before-event、零亮度保护和错误恢复策略未改。
