# 卷帘通信策略：原生验证候选（尚未证明实机根因）

本轮恢复「启用此卷帘的日常控制」：未保存偏好时默认关闭；原 `curtain.daily.enabled` 名单原样恢复。开启后才允许手动控制并加入统一 10/30 秒轮询。开关本身不发包，不清除跨重启保留的暂停；手动读取仍可独立使用。已有暂停不得为测试自动清除。普通设备和桥接缓存策略不变。

初始交付面向家庭 Mac 的编译、离线及 loopback 验证；这些原生与模拟验收现已完成。当前按本页末尾最新授权进入指定单台只读试验，N 组完成后再按结果进入真实 App 长测。四项通信策略仍是待实机区分的候选，实际结果和根因进展以下方已完成记录为准。

## 已实现的正式策略

- 精确型号 `dooya.motor.dc1545` 每个客户端创建独立、串行、绑定的 UDP socket；会话内 hello/info/读/写/回读复用同一源端口。核对远端 IP/端口、设备头及 RPC ID；错包/旧包不重置超时，也不触发重发。关闭、取消或重配释放 socket。
- 初次、手动读取和运动前置校验仍读取六项 2.2/3/4/5/9/10。普通轮询改为 2.2/3；最多十次精简读取或距完整校验达到 300 秒后重新完整校验。不会忽略故障/模式属性错误。写入仅一次，确认仍使用实际位置和停止状态；保持紧急停止调度。
- 最近 hello 与有效应答时间分开记录；hello 硬期限 120 秒，卷帘预留调度间隔在 110 秒后检查重新校时。连续应答不会无限推迟 hello；周期校时不重新执行不必要的 info。无暗重试。
- 新 stamp 取 hello 的设备时钟加单调经过秒数，不逐包额外加一，也不将回显应答变成新锚点。应答偏差超过 ±5 秒即停止该请求并暂停；这是软件的失败边界，尚非固件兼容性结论。
- 脱敏日志增加会话/socket/源端口、RPC ID、请求地址、stamp/偏差/hello 年龄、实际 sent、累计包数、队列等待和逐项安全标量。失败批次先记录所有项再抛错。完整收发仍有界 64 MiB，关键历史另留 4 MiB。

## 本地先做离线验证

```sh
swift build --product mijia-lan --force-resolved-versions
swift build --product MijiaLANApp --force-resolved-versions
swift test --force-resolved-versions
swift test --filter UDPDiagnosticsTests --force-resolved-versions
swift test --filter MiioPolicyTests --force-resolved-versions
```

UDP 回环测试只访问 127.0.0.1 上测试自行创建的临时端口，无真实设备凭据。覆盖 64 次旧 socket、256 次同会话端口稳定、关闭释放、取消和错端口/错 RPC/错设备头拒绝。时钟模拟覆盖真实时钟、回显、延迟、回退/跳变及跨多个 hello 周期。预览设备时钟同步改为单调推进，不能继续使用固定 5000 的模拟应答。

若正式 Matter 已占 UDP 5540，全量 JS 测试可能遇端口冲突；不要为本轮验证停止正式桥接或操作正式配对。

## 只打印测试计划（无网络、无配置读取）

```sh
.build/debug/mijia-lan curtain-experiment --socket stable --layout adaptive --hello periodic --stamp helloAnchored --slot 1 --reads 48 --interval 30
```

四条轴均为显式必填，不从环境启用真实通信。只有额外提供 `--execute --baseline-normal --log-directory NEW_DIRECTORY` 才读取标准输入中的 `LocalHomeConfig` 并执行。`--slot` 是这份私有输入配置的设备次序，**不是**以前 App run 的 C 编号；不要将 token、IP、DID 或私有配置贴进命令或聊天。本命令只读，不允许 set/action。日志目录必须不存在，新建权限 0700。实机执行须遵循本页末尾最新授权范围，只选择已恢复正常基线的指定单台。

单因素矩阵（按最新授权先运行 N 参考组；其他组需根据结果选择，不自动轮换）：

| 组 | socket | layout | hello | stamp | 与旧基线相比 |
|---|---|---|---|---|---|
| B0 | fresh | full | silence | replyPlusOne | 旧策略对照 |
| S1 | stable | full | silence | replyPlusOne | 仅会话端口 |
| R1 | fresh | adaptive | silence | replyPlusOne | 仅查询负载 |
| H1 | fresh | full | periodic | replyPlusOne | 仅周期校时 |
| T1 | fresh | full | silence | helloAnchored | 仅 stamp |
| N | stable | adaptive | periodic | helloAnchored | 新正式策略参考 |
| P1（可选） | fresh | single | silence | replyPlusOne | 仅六属性拆包，不能预设拆包能修复 |

`reads` 是轮次数，不是 UDP 包数：single 每轮六包，full 每轮一包，adaptive 精简/完整交替，hello/info 另外计数。分析必须同时按时间、总包数、每种地址组合次数比较，不能仅比较轮数。single 的六个有间隔请求还会拉长轮次；它是拆包布局对照，并非等负载对照。

所有组均显式选择单台、有限轮次（最多 48）、不自动轮换；第一处超时、属性错误、缺值、不可信值、时钟异常或丢弃回包后终止。SIGINT 取消并关闭会话，不继续循环或重试。输出包含 outcome/完成轮数；异常、取消或丢包终止以非零退出，完整跑完才成功退出。手机控制失效也必须人工停止。只读测试不能证明控制或物理动作成功。单组成功或 N 成功不能唯一定位根因；必须有正常基线、对应字段和可重复单因素差异，必要时再设计交互对照。

## 云端验证与交付边界

- 126 项隔离 Swift 回归通过：实际 UDP 传输、会话/时钟策略、逐项失败日志、旧样本、轮询、开关/暂停偏好、App 提交与草稿、Matter 缓存及 64 MiB 滚动/流式导出。
- UDP 回环含 256 次稳定端口、64 次旧 socket；另有 72 次 RPC + 18 次 hello、同一端口跨 **36 分钟模拟时间** 的联合验证。不是在设备上或墙钟 36 分钟运行。拒绝错端口、错 RPC、错 DID，排空下一请求之前已到的旧副本，取消与关闭释放端口。
- 时钟模型覆盖真实时钟、回显、延迟、回退/跳变。追加回归发现并修正长空闲后 hello 已成功、旧 RPC 年龄仍误判新握手过期的软件缺陷；这不能解释现场持续通信故障。
- 113 个 Swift 文件语法检查通过；Matter 原套件 7/7 通过。Linux harness 使用真实 socket/调度，但 AES/MD5 编解码仍为替身，App 视图只做语法检查；完整原生类型检查、真实编解码与 SwiftUI 预览由家庭 Mac 补齐。
- 现场报告已收入 [11 月 9 日记录](household-followup-diagnostics.md#2026-11-09-持续读取后六台异常最新现场统计) 和回归 fixture，严格分开全局/每台前缀、成功样本与缺失的失败值。

没有安装正式 App、实机读写、自动恢复暂停、重置配网、固件升级或 Release。尚未证明哪一项是固件故障根因。确认硬件恢复正常之前不要执行下述实机模式。

### 待正常基线恢复后的单次执行方式

仅在届时用户明确选择的单台及组上使用。先退出 App/桥接/其他探针，确认不是故障持续状态；不要为取配置运行会扫描的 App。将**已存在的私有配置**从 stdin 重定向给命令，配置不落日志，不将 token 放 argv。比如下面的 S1 只改 socket，其余保持旧策略：

```sh
umask 077
.build/debug/mijia-lan curtain-experiment --socket stable --layout full --hello silence --stamp replyPlusOne --slot 1 --reads 48 --interval 30 --execute --baseline-normal --log-directory /tmp/mijialan-S1-new < /private/path/existing-config.json
```

输入路径是占位符，`slot 1` 必须核对为当次选定的设备；日志目录必须尚不存在。没有私有配置时可复用[既有安全钥匙串管道](household-followup-diagnostics.md)向 stdin 传递，不单独打印 `security ... -w` 输出，不修改钥匙串 ACL、不执行 `tee`/`set -x`。只选这一个组，不自动执行整张矩阵。S1 命令是后续单因素示例；当前阶段与首轮组别以本页末尾最新现场准备记录为准。


## e57af3c 的 macOS 原生验收反馈

来源：本地线程 `01a1b156-dd7f-7873-88dc-943821f74830`，验证提交 **`e57af3c8195b8845b06b970e6e8adab040567ec8`**。以下为本地实际观察与统计的转述；云端未打开本地证据文件。证据目录为本机 `/tmp/mijialan-e57af3c.M8FdFm`，含各组 wire/traffic/stdout 和 `verification.json`，该路径不能假定在云端存在。

### 已完成

- Xcode 27.2 原生 App/CLI 编译通过，完整 Swift 测试 **253 项通过**（13 + 161 + 32 + 47），包括实际 UDP 和真实 AES 回环。Debug App 打包、图标及 deep/strict 签名验证通过。
- Matter 原套件因正式进程 91747 占 UDP 5540 为 6/7；仅临时副本改用 15540 后 **7/7**。正式桥接保留，未为验证停止或修改。
- 真实编译 CLI 的七种 plan 全部正常输出，输入无效 stdin 也未被读取；arming 参数不完整时拒绝执行。
- B0/S1/R1/H1/T1/N/P1 七种策略各对 **127.0.0.1 动态端口的模拟卷帘执行两轮**。fixture 凭据在内存生成，使用实际 Swift AES/MD5 与 Python OpenSSL 对端编解码，正常组共 **38 个实际 sent**。未加载家庭配置。
- 四种异常：9/10 返回 -4004、错 RPC 后跟正常应答、stamp +100 跳变、SIGINT 取消，各只发送 hello/info/read 三包后非零退出，无后续读取或写入，异常组合计 **12 包**。
- 全部 **50 个实际 sent** 与落盘 journal 的数量、源端口、RPC ID/stamp、地址布局吻合。stable 组只有一个实际源端口，fresh 每次 socket ID 独立；累计 hello/info/read 计数一致，正常 response ID 匹配。调度等待可通过 exchange 关联到 attempt 字段。
- 失败批次保留了 code0 的模拟位置 29 及 9/10 错误；时钟拒绝有 `clockAccepted=false`，错 RPC 有 `discarded` 并终止。日志未包含 token、IP 或 fixture 设备名。全部 CLI 回环无写包。
- 独立 bundle ID、preview/ephemeral 原生预览：开关默认 off，off 期间无模拟卷帘请求；on 后共享轮询先六项、后 2/3 精简批次。自动刷新保留未提交文字 `64.`，没有忙状态或阶段跳变；点击真实确认按钮完成模拟 29→34，仅一次 write attempt，随后 `confirmed34`。关闭开关后停止后续模拟轮询。设置显示 **10/30**。

### 解锁后的补充完成项

同一本地线程随后反馈：

- 用户解锁后实际打开诊断日志页面，确认显示 **64 MiB + 4 MiB** 及新增 packet 字段说明。
- 经原生 `NSSavePanel` 成功导出 `native-export.jsonl`，**4556 行全部可解析且 scope=simulation**，包含本轮模拟 `confirmed34` 的完整操作链。
- 隔离预览已通过自身退出并收纳为 `UI-Preview.verified-build`；正式 App 未替换。本轮原生检查全部完成，无需 e57af3c 之后的代码修正。此前锁屏造成的待检查项已完成。

### 下一阶段：单台实机对照准备

按本地线程报告，已按用户要求通过正式 App 自身 Cmd-Q 正常退出；原 App PID **91606**、Matter PID **91747** 均确认结束，没有其他测试探针。此退出发生在上述原生验证完成之后，不改写先前 Matter 验证期间正式桥接保留的事实。

**此时尚未发送任何实机测试包。** 下一步先由用户恢复一台卷帘，并确认手机米家确实能驱动物理动作；正常基线确认后，先只对选定单台执行 **N 组（stable / adaptive / periodic / helloAnchored），只读 48 轮、目标轮间隔 30 秒**。沿用前文的显式 arming、独立日志目录和异常停止规则，不自动执行其他组。

现有六台 `propertyError` 暂停配置继续保留，不在正式 App 清除或恢复。后续根据 N 组和手机/实物观察结果再安排单因素对照。N 组通过可作为新策略参考，持续读取故障的具体原因仍需可重复的策略差异与日志证据。该准备阶段结束时，基线恢复、N 组实机结果及长期稳定性仍未完成；随后进展见下一节。


### 用户更新授权：指定单台只读与 App 长测

本地线程随后反馈用户准备休息，明确授权其自主继续测试，范围只包括 **「透明卷帘-客厅」**，其余五台不参与通信。用户已重启目标并确认手机米家能驱动实际动作；本地正在用 e57af3c 的 CLI 执行 **N 组只读 48 轮/30 秒**，该报告尚未包含完成结果，没有控制写入。

最新验收判据为连续读取的返回码、严格校验和详细日志，用户本轮不要求追加手机或实物动作验证。此前的恢复基线确认已完成；之后的通信成功仅按通信结果记录，物理控制不属于这次只读验收。

接续安排为：先完成 N 参考组，确认测试程序及返回结果正常后，启动新版真实 App，仅为该目标开启状态读取进行长时间测试；这一 App 阶段在报告时尚未开始。只启用目标的读取路径，其余五台保持不发包。若目标的已保存暂停妨碍读取，应使用现有明确手动读取并严格校验的恢复入口，不批量删除暂停配置，不恢复其他五台。日常控制开关本身不发送控制命令，长测期间不使用位置/开/关/停。

CLI 与 App 不并行访问目标；不在用户休息期间执行物理控制、重置或固件变更。任何阶段异常即停止该阶段，保留会话、端口、RPC、stamp、请求布局及逐项结果交回云端排查。在这一阶段授权下不进行无人值守危险回退；随后扩大到逐项回退的最新授权及停止条件见末尾夜间排因设计。N 及 App 长测即使通信持续正常，也只提供修订组合的稳定性证据；唯一根因仍需相应单因素差异。


### e57af3c 单台真实 CLI N 组完成

本地线程反馈指定客厅透明卷帘的 N 组只读 **48 轮全部成功、exit 0**，实际持续 **1490.043 秒（约 24 分 50 秒）**。实际 sent 共 **61 包 = hello 12 + info 1 + read 48**，其中 **5 次完整六项、43 次 2/3 精简**。客户端和源端口各只有一个；错误、丢弃、超时和写入均为 0，持续读数为 0%/停止。stdout 为 complete 48 / writes 0，socket 正常关闭。此为通信层的完整结果，本轮不追加手机/实物验证。

证据由本地保存在 `/tmp/mijialan-live-N-20261110.5vx6dyii/` 的 `journal/traffic.jsonl`、`summary.json`、`run.json`；云端未打开这些本地文件。该时间和读取轮数已超过旧现场首错窗口，但只有五次完整六属性读取，尚不足以覆盖旧约 37 次成功六项的累计暴露。后续计划为新入口原生验证通过后，真实 App 单台只读 **14400 秒**；正式 App/桥接仍退出，其余五台不动。N 通过作为修订组合的参考，不归结为唯一根因。

新增 [DEBUG 单台真实 App 长测入口](read-only-app-soak.md) 专供该阶段：严格门控、私有 FIFO 种子、内存 vault/独立 defaults、磁盘 experiment 日志、统一后台 30 秒轮询、实际发送入口禁写、故障与时限结束。该入口不改变 e57 四项通信算法；先做本地原生构建和假种子进程级验证，再用于获授权的目标。

真实 App 后续进展：44958fa 已通过三例实际进程/AES 回环（缺 arming 零包、-4004 三包后暂停退出、75 秒后台正常三轮且同源端口）。本地随后按授权安装验证包并启动单台四小时隔离只读长测；正式配置/六台原有暂停未变。四小时结果尚待反馈，不能将 N CLI 的 48 轮成功写作 App 长测完成。详见[进程级验收与长测状态](read-only-app-soak.md#44958fa-真实-app-进程级回环通过单台长测已启动)。


### 最新夜间排因设计：相对 N 的逐项回退

本地线程再次转述用户明确授权：仅指定客厅透明卷帘自主测试各疑点，不要求追加手机或实物确认，任何异常即停止整晚后续阶段，不自动重启/重置硬件，其余五台不动。此前较窄的“不做危险回退”阶段安排由本节明确的有限顺序替代；不自动扩展到其他设备或无限循环。

顺序为先完成正在进行的四小时真实 App 修订 N 基线；**只有正常完成才进入后续 CLI**。先退出 App、确认其后台结束，CLI 与 App 不并行。后续每组只读 48 轮、目标开始间隔 30 秒，策略为：

| 阶段 | socket | layout | hello | stamp | 相对 N 的改动 |
|---|---|---|---|---|---|
| socket 回退 | fresh | adaptive | periodic | helloAnchored | 仅 socket |
| layout 回退 | stable | full | periodic | helloAnchored | 仅读取布局 |
| hello 回退 | stable | adaptive | silence | helloAnchored | 仅 hello |
| stamp 回退 | stable | adaptive | periodic | replyPlusOne | 仅 stamp |
| 交互组（前四组均正常才做） | stable | adaptive | silence | replyPlusOne | hello + stamp |
| B0（此前阶段均正常才做） | fresh | full | silence | replyPlusOne | 完整旧组合 |

每阶段之前只做一轮 N 完整读取，确认没有现存可见协议异常；此前置会产生自己的 hello/info/read，也要单独保留 run、会话和日志。不要把它的包数并入变体本身，也不能在跨阶段分析时漏掉其累计暴露。每阶段使用新日志目录、显式策略参数和有界轮次；对整晚汇总累计包数、完整/精简/逐项地址次数、hello 次数、时间、错误与阶段边界。

硬件不在阶段间重启，时间/顺序/此前累计请求会影响后组；前置 N 成功仅说明这一刻的校验通过，不是固件内部状态已重置。差异先记为强候选，不以一次串行差异认定唯一根因。B0 与 N 是组合对照，不能独立归因到单一轴。错误、丢弃或其他异常后不继续前置 N 或下一组，不自动尝试恢复。

**当前 App 停止条件的实现边界**：44958fa 的 App 模式在统一回调中检查 `pausedPolling` 和日志存储失败；它不会仅因 `discarded` 后又收到合法回包就自行退出。CLI 则已有 discarded 终止。因此当前不更换正在长测的版本，由本地独立日志监视将 discarded 也作为整晚停止条件，结束当前阶段并取消后续，不只看 `result.json`。该监视只读本地日志，不发送探针；若用外部终止方式，记录方式并核对进程退出，不把它记为 deadline 正常完成。

### 新增时钟观测与 App 首轮状态

本地反馈 N 组 **49 个 RPC 的 response stamp − request stamp** 分布为：0 秒 25 个、1 秒 23 个、2 秒 1 个。回复并非全部原样回显；旧算法在回显模型中的累计偏差仍是待验证假说。上述统计是响应与请求之差，区别于 journal 中相对 hello 预测时钟的 `estimatedClockSkewSeconds`，不应互换。

真实 App 长测首轮后台读取成功，反馈进程 PID **99900**，源端口一致、无写入；四小时完整结果及后续各变体均尚未提供。
