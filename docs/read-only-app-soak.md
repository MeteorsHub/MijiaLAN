# DEBUG 真实 App 单台只读长测

**最新状态：44958fa 的 N App 单台长测约2小时49分时在完整查询复现-4004及2.5类型损坏，四小时验收提前失败。App/CLI均已停止，后续轴对照取消；见[现场证据与属性隔离工具](curtain-attribute-isolation.md)。此页保留入口行为与阶段验收记录。**

此入口使用真实 `AppModel → HomeStore → CapabilityHomeProvider → DeviceController → CurtainControlController` 统一后台轮询。配置来源改为受控私有 seed，凭据存内存 vault，默认值使用全新随机 suite；不读取正式钥匙串、不修改正式配置、六台暂停或配对。四项通信策略保持 e57af3c 的 N 组。它是隔离配置来源的真实 App 测试，不作为正常钥匙串加载验收。

当前五字段兼容候选沿用本页门控/调度；manifest明确记录 `dc1545-fw1.1.3-normal-five` 和实际五项地址。后文44958fa的full6历史结果不改名、不算作新候选已验收。详见[当前候选](curtain-five-property-compatibility.md)。

## 启动契约

仅 Debug 有效，以下条件缺一即在 AppModel、vault、设备 API、发现初始化**之前退出，退出码 2**，不回退到普通模式：

- `MIJIALAN_EPHEMERAL=1`
- `MIJIALAN_READ_ONLY_APP_TEST=1`
- `MIJIALAN_SEED_CONFIG`：绝对路径，当前用户所有、组/其他用户无权限的普通文件或 FIFO，不接受符号链接。实际凭据使用 0600 FIFO；假配置可用 0600 普通文件。
- seed 必须恰好一台 `dooya.motor.dc1545`、正确 v1 URN、有效十进制 DID、32 位十六进制 token、IPv4 地址，无 skipped 条目。
- `MIJIALAN_READ_ONLY_APP_TEST_LOG_DIRECTORY`：**尚不存在**的新目录，父目录必须已存在；入口原子创建 0700 目录，不重用或修改旧目录。
- `MIJIALAN_READ_ONLY_APP_TEST_SECONDS`：整数 1…43200，实际本轮设 **14400（4 小时）**。
- 不允许同时启用 UI preview / snapshot 或 `MIJIALAN_PANEL_OPEN_ON_LAUNCH=1`；不运行 DevSnapshot。创建普通 `MenuBarPanelController`，保留状态项、隐藏面板窗口、NSWorkspace 通知及正常后台生命周期。面板保持隐藏，测试模式的 reopen/展示请求不打开面板。后台固定 30 秒，前台默认5秒（manifest与configure共用DevicePollingIntervals默认值），仍由原统一调度减去轮次耗时。

仅残留测试选项、没有正确完整标志时也会拒绝。Release 收到测试选项时拒绝启动该模式。没有这些测试选项时普通 App 行为保持原样；旧的普通 `MIJIALAN_EPHEMERAL` seed 行为不改。

FIFO 专用读取使用 nonblocking open/poll，等待最多 **30 秒**、内容最多 **256 KiB**，检查类型、所有者和权限；没有 writer、种子不完整、错误 JSON 或多设备均失败关闭。本地与 Linux 已用假数据证实 `FileManager.contents(atPath:)` 对 FIFO 返回 nil，因此该模式不使用旧加载方法。FIFO 只在本次读取时打开，不打印路径、配置或底层系统错误；生产者应一次写完并关闭，之后删除管道。

## 本地先验入口，再长测

先用回环假设备和假 seed 编译验证：

```sh
swift build --product MijiaLANApp --force-resolved-versions
swift test --filter ReadOnlyAppTestTests --force-resolved-versions
bash scripts/build_app.sh debug
```

仅回环验入口时可显式设置 `MIJIALAN_READ_ONLY_APP_TEST_PORT` 为模拟服务器的 1024…65535 动态端口，时长可设 2 秒或足够完成一次冷读取的 20 秒；默认设备端口 54321。此选项也受完整门控约束，不能独立改变普通运行端口。

已授权单台实机时，先结束 CLI，不与 App 并行访问目标。使用本地已准备的私有 FIFO 和新日志子目录，例如以下变量均只是路径，不含设备标识/地址/token：

```sh
MIJIALAN_EPHEMERAL=1 \
MIJIALAN_READ_ONLY_APP_TEST=1 \
MIJIALAN_SEED_CONFIG="$seed_fifo" \
MIJIALAN_READ_ONLY_APP_TEST_LOG_DIRECTORY="$test_root/app-traffic" \
MIJIALAN_READ_ONLY_APP_TEST_SECONDS=14400 \
build/MijiaLAN.app/Contents/MacOS/MijiaLAN
```

`app-traffic` 不要提前 mkdir。只在既有合法授权可读取钥匙串时由外部生产者在内存筛选一台，通过 FIFO 交付；不打印凭据、不写私有配置磁盘、不修改 ACL，不绕过锁屏、SecurityAgent 或系统权限。权限阻塞会让 seed 超时或后续只读失败并结束；无需要求休息中的用户点击。

## 只读、日志和结束

- 隔离配置仅含唯一卷帘，使用正常默认自动刷新，无opt-in偏好。HomeKit/Matter 不附加、不启用，不发发现广播；普通菜单栏控制器存在但面板保持后台隐藏，不自动控制。
- `CurtainControlController` 的实际请求入口拒绝 position/open/close/stop；`LANMiotAPI` 拒绝写入与 action，创建的专用 session 也设置 `allowWrites=false`。不是依赖不点击按钮实现只读。
- 详细日志 `traffic.jsonl` 的 scope 为 **experiment**，完整收发滚动 64 MiB，关键历史另留 4 MiB；保持原有脱敏字段及流式导出格式。`plan.json` 仅含时长、策略、端口和设备数等安全元数据，不含 seed。
- App 在该有界测试期间持有临时 userInitiated 活动，避免空闲睡眠/App Nap影响轮询；结束释放，不改变系统电源偏好或锁屏。
- 只读隔离测试发现属性错误、缺值、时钟/身份异常或超时后，同一回调结束整个实验，不自动恢复或重试。生产模式则按统一轮询退避检查，详见正常使用迁移说明。检测日志存储失败也结束。
- 达到时长上限或出现上述故障时，等待卷帘任务结束、关闭会话/socket、停止统一循环、flush 日志，写 `result.json`，随后 `NSApp.terminate` 正常退出。`outcome=durationComplete` 仅表示达到上限；`outcome=paused` 表示异常提前结束，`reason` 保留原因。应以结果文件和日志判断，不能只看进程退出码。故障时没有自动回退到其他策略。
- 四小时用于积累精简读取和约每 300–330 秒一次的完整校验。实际成功轮数和当前完整五项次数以日志为准（旧44958fa记录为六项）；通信结果不作为物理动作成功证据。

## 云端验证边界

新增 **6 项回归通过**，隔离完整 Swift **132 项通过**，**115 个 Swift 文件语法检查通过**。新增回归验证门控与默认无效、无效/多台/不安全 seed、0700 新目录、FIFO 成功及无 writer 超时、实际控制器/接口拒绝写入与 action、统一 DeviceController 成功只读、故障停止、日志重开和有界 deadline。Linux harness 的编解码为替身，AppModel/AppKit 生命周期只做语法检查；完整原生构建及进程级回环需家庭 Mac 补齐后再使用真实目标。没有修改 e57 通信算法，没有在云端发实机包。


## 菜单栏生命周期修正

bbfe803 的初始入口曾跳过 `MenuBarPanelController`，只覆盖真实 App 后端和调度。后续最小修正是在相同的 App 启动回调中先创建普通菜单栏控制器，再启动只读 lifetime；保留窗口、状态项和 NSWorkspace 生命周期，并通过门控及展示入口禁止切到前台。普通用户模式不变。此修正不改变四项通信策略；后台生命周期的进程级回环与正式四小时长测需基于修正后的提交进行，先前六项原生回归成绩仍对应 bbfe803。


有界时长从 `ReadOnlyAppTestLifetime.init` 捕获的绝对 ContinuousClock 截止点计算，任务调度延迟不会延后其计时起点。期限回归等待明确完成事件后检查停止幂等，移除固定 sleep 1100 ms 的调度假设。bbfe803 在本地全量并行测试中暴露的 lifetime 断言竞态由此修正；旧 PanelMemory 的独立复测仍由本地分类，本提交不据此改动窗口关闭逻辑。

本次菜单栏/绝对期限后续修正：云端入口定向 **6/6** 通过（包括 open-on-launch 参数拒绝），115 个 Swift 文件语法检查通过。菜单栏窗口与 NSWorkspace 通知的真实进程验收、全量原生测试继续由本地执行；未向实机发包。


## PanelMemory 原生测试 fixture 等待修正

本地在锁屏状态下定向复测仍复现旧 `PanelMemoryTests.exitCompletion` 的两个断言失败。该测试此前用两段固定 200 ms sleep 假定 120 ms AppKit 动画已结束；此次仅修改测试 fixture：以实际 `.open` / `.closed`、didClose 次数及窗口隐藏为完成条件，短步泵送默认 AppKit run loop 并让出主 actor，单阶段最多等待 5 秒；defer 清理窗口，不用清理动作提前满足断言。生产 `PanelPresentation`、窗口关闭和通信逻辑没有改动。云端只能执行语法检查，锁屏下真实 AppKit 完成行为仍待本地原生复测，未据此宣称 UI 已验证修复。

## 44958fa 本地全量原生复测

来源为家庭 Mac 本地线程反馈，代码提交 `44958fa18a3282fea2e891d312e1a3975b9a380e`。原生测试分组 13 + 161 + 47 全部通过，App 38 项中 37 项通过；合计 **258/259**，不是全套通过。只读入口 **6/6** 均通过，lifetime 的固定等待竞态未再出现。

唯一剩余失败为锁屏下旧 `PanelMemoryTests.exitCompletion` 的 reopened 断言（line 123）：等待 5 秒仍未进入 `.open`。生产窗口逻辑未改；本轮不继续围绕该锁屏动画反复调整 fixture，也不将它归为已修复。日志由本地保存在 `/tmp/mijialan-44958fa-tests.out`，云端未打开该文件。

本地下一步计划为真实 App 进程级回环，验证正常后台 30 秒、deadline 退出及 -4004 故障停止；这些进程级结果在本次反馈时尚未提供。完成后才进入已授权客厅透明卷帘单台四小时只读。N 组实机 48 轮成功沿用前述证据，与 App 长测分开记录。没有新增代码修正。

## 44958fa 真实 App 进程级回环通过，单台长测已启动

同一本地线程追加反馈：44958fa 的真实 App 已完成打包和签名验证。使用仅允许 127.0.0.1 回环的本地 sandbox，对真实 App 进程和实际 AES/MD5 编解码完成三例验证：

| 场景 | 实际通信及结果 |
|---|---|
| 缺少 arming | 退出码 2，0 包 |
| 首轮完整六项的 9/10=-4004 | hello/info/read 各 1；结果 `paused/propertyError`，正常退出，无后续读取或写入 |
| 后台正常运行 75 秒 | 到 deadline 正常结束；3 轮为 full6、compact2、compact2；hello 1、info 1、read 3，同一源端口，来源 `backgroundPoll`，日志脱敏，无写入 |

这些是模拟回环进程级验收；不替代仍失败的锁屏动画测试，也不改变先前原生测试 258/259 的记录。本轮未因此修改代码。

随后本地已按用户授权将验证包安装/替换到 `/Applications/MijiaLAN.app`，并启动指定客厅透明卷帘 **四小时真实 App 只读 soak**。此时安装状态已由“正式 App 未替换”变为“验证包已安装并启动隔离长测”；正式配置及原有六台暂停记录保持不变。进程使用独立 memory vault/suite、单台 seed 和隐藏的正常菜单栏面板，不与 N CLI 并行，不执行写入。报告尚未提供四小时结果，仍记为进行中。

先前 N CLI 实机 48 轮成功单独保留。当前已有进程级回环与单台 CLI 通信证据，历史持续读取故障的独立根因仍未确定。


夜间授权后续扩大为 N App 正常完成后、同一台有界 CLI 逐项回退，见[最新排因顺序与停止条件](curtain-communication-experiments.md#最新夜间排因设计相对-n-的逐项回退)。当前运行 44958fa App 的自停只覆盖读取暂停/存储失败；discarded 后跟合法回包不一定自停，本地需监视该事件并结束当前及后续阶段。本次仅记录计划和实现边界，不修改或替换正在运行的测试版本。
