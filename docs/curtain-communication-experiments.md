# 卷帘通信策略：原生验证候选（尚未证明实机根因）

本轮恢复「启用此卷帘的日常控制」：未保存偏好时默认关闭；原 `curtain.daily.enabled` 名单原样恢复。开启后才允许手动控制并加入统一 10/30 秒轮询。开关本身不发包，不清除跨重启保留的暂停；手动读取仍可独立使用。已有暂停不得为测试自动清除。普通设备和桥接缓存策略不变。

这是供家庭 Mac **编译、离线及 loopback** 验证的候选。不要安装替换正式 App，也不要向目前故障的设备发包。新策略针对四项候选缺陷，不能据此认定根因。原生构建、真实加密编解码、实机长期稳定性尚未验证。

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

四条轴均为显式必填，不从环境启用真实通信。只有额外提供 `--execute --baseline-normal --log-directory NEW_DIRECTORY` 才读取标准输入中的 `LocalHomeConfig` 并执行。`--slot` 是这份私有输入配置的设备次序，**不是**以前 App run 的 C 编号；不要将 token、IP、DID 或私有配置贴进命令或聊天。本命令只读，不允许 set/action。日志目录必须不存在，新建权限 0700。当前不要执行实机模式。

单因素矩阵（先列出，需先恢复正常基线并另行安排现场观察）：

| 组 | socket | layout | hello | stamp | 与旧基线相比 |
|---|---|---|---|---|---|
| B0 | fresh | full | silence | replyPlusOne | 旧策略对照 |
| S1 | stable | full | silence | replyPlusOne | 仅会话端口 |
| R1 | fresh | adaptive | silence | replyPlusOne | 仅查询负载 |
| H1 | fresh | full | periodic | replyPlusOne | 仅周期校时 |
| T1 | fresh | full | silence | helloAnchored | 仅 stamp |
| N | stable | adaptive | periodic | helloAnchored | 新正式策略参考 |
| P1（可选） | fresh | single | silence | replyPlusOne | 仅六属性拆包，不能预设拆包能修复 |

所有组均显式选择单台、有限轮次（最多 48）、不自动轮换；第一处超时、属性错误、缺值、不可信值、时钟异常或丢弃回包后终止。SIGINT 取消并关闭会话，不继续循环或重试。手机控制失效也必须人工停止。只读测试不能证明控制或物理动作成功。单组成功或 N 成功不能唯一定位根因；必须有正常基线、对应字段和可重复单因素差异，必要时再设计交互对照。

## 当前云端验证及未完成项

隔离 Swift harness 121 项通过，使用实际 UDP socket/传输/串行调度、App 控制器与日志实现；Linux 的报文加密使用替身，所以真实 AES/MD5 与原生 SwiftUI 类型检查仍需本地补齐。此候选尚待追加：更完整的暂停开关迁移与精简轮询后完整校验失败回归、现场统计文档汇总，以及最终全量离线复查。没有实机请求，没有根因结论。
