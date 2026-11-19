# Matter 布局迁移、状态恢复与协议诊断

## 现场依据与修复范围

2026-11-19 家庭 Mac 报告：54e4743 已通过本机 App/CLI 编译、376 项 Swift 与 24 项 Matter 测试。ceiling20 在 App 两路数据有效，Aqara 仍离线。旧单灯应用端点 19 保留，但 BDBI/Reachable 被搬到新实体端点 21，副灯为 22。原路径 `19/0x0039/0x0011` 在本机协议模拟中返回 UnsupportedCluster，新父端点为 true；配置版本仍为 1。重新连接桥接及重进 Aqara 后用户仍报告离线。没有取得当时 M200 实际 Read/Subscribe/Report 追踪，缓存旧路径是待验证的解释。

同一报告中，客厅透明卷帘 12:34:48 提交原生目标 19%，12:34:53 写入 code=0，12:35:06 确认阶段超时；后台 12:35:40 已读到实际 19%/停止，Matter 存储 12:35:41 为 8100，用户 Aqara 卡片仍是 100%。书房透明实际 18%、Matter 8200、Aqara 18%，因此保留原生开度与 Matter 闭合度的转换：`(100 - native) × 100`。没有把持久化属性值当成已发报告或被 M200 接收的证据。

本轮修复已确认的迁移缺口、恢复提交顺序，并加入协议追踪。尚未在云端复现 M200 单台卷帘卡住的故障机制。

## 保留实体路径的组合升级

若存储表明某实体原来是平铺单功能端点，升级为多功能时让该端点继续承载主功能和唯一的 Bridged Device Basic Information，副功能成为其子端点。组合父端点可以同时具有应用功能；子端点不重复声明实体身份。

- 从原单灯直接升级，主灯原编号、OnOff/调光/色温路径与 Reachable 路径保留，只新增副灯。
- 对已经过 54e4743 的迁移，若仍能定位历史平铺存储与当前主功能编号，则恢复以原主功能编号承载实体身份；保留副灯编号、UniqueID 和最近保存的自定义 NodeLabel。旧纯组合父端点退出 Descriptor，不再保留第二份身份。测试重放了平铺 → 54 迁移 → 新版的完整存储链。
- 原本就是组合、没有历史平铺实体的设备继续使用既有组合父端点。没有历史存储时不猜测编号。
- 使用原节点内部独立布局清单保存结构签名和配置版本。签名涵盖编号、父子关系、设备类型、服务、属性与命令集合，不包括动态状态或设备名称。布局改变时调用库的 `BasicInformationServer.increaseConfigurationVersion`，同时更新受影响实体已启用的可选 ConfigurationVersion。普通快照或相同布局重启不递增。
- 保留节点/fabric、网络配置、commissioning 配置、设备选择、HomeKit 与米家配置。没有调用配对重置。

原本缓存旧实体编号的控制器可以继续读原路径；支持配置版本的控制器也可通过版本变化和 Descriptor 重建布局。已经把中间版本新父端点缓存为实体的控制器仍需发现新 Descriptor。**M200 是否采用版本通知并清理旧布局，必须本机确认**；若仍离线，先导出实际 Read/Subscribe 路径与返回状态，保留当前两组配对，不自动重配。

## 卷帘缓存恢复

共享缓存同步串行处理；同一单功能/主功能实体的 Reachable 与应用属性在一次端点事务中提交。纯组合实体先更新子功能，再发布父端点恢复可达，避免先显示在线、随后才更新读数。实际位置、整数闭合百分比、目标闭合百分之一与运行状态沿用可信驱动缓存。失效缓存不合成实际位置；确认失败之后，正常后台有效缓存可恢复属性和订阅报告。

本轮没有增加设备读取或定时器，没有全局反转方向，也没有为诊断发送实际控制。

## 正式诊断日志

设置 → 诊断日志，切换到完整收发视图，或导出全部历史。Matter 事件嵌在原 JSONL 的 `matter` 字段，复用原完整日志总上限 **64 MiB** 和独立关键历史上限 **4 MiB**。旧日志仍可读，查看/导出仍为有界读取/流式导出。

同一 App 日志的 `run/sequence` 定位全局事件；`matter.run/sequence` 标识一次 sidecar 及其事件顺序，`matter.milliseconds` 是其单调相对时间。设备使用与 App 相同的本地 C 代号；协议会话和交换使用仅当前 sidecar 内有效的匿名序号，`caseSession` 表明 CASE。RPC 的 `request` 可与 App 内相同请求及 LAN 操作 UUID 对照。真实 fabric/node 标识、名称、地址、密钥、配对码与私密原始报文不落盘。

| 事件 | 能确认的阶段 |
|---|---|
| started、layout、layoutChanged、configuration | 布局签名、版本、实体/功能端点编号、父子关系、类型和服务/属性清单；迁移时包含旧实体编号 |
| snapshot | App 缓存快照已到达；`changed=false` 时输入与上次相同，不重复记录所有标量 |
| attributeInput | 缓存变化时的原生输入与转换结果；`native=true/false` 区分，含可达性/未知原因。主灯色温原生值来自已校验的 Kelvin 缓存，非原始 LAN 报文 |
| attributeCommitted | 库的属性提交事件，含路径与 dataVersion；可对照对应输入及后续报告 |
| readRequest、subscribeRequest | 已认证控制器实际请求的路径，订阅请求的最小/最大间隔和匿名会话 |
| subscriptionAttached、subscriptionResumed | 库将订阅附着到会话；同一订阅对象换会话时记 resumed，不能单凭它断言对端已恢复 |
| subscriptionEstablished | SubscribeResponse 已交给传输，包含订阅编号及实际协商最大间隔 |
| reportQueued | 报告交给交换层，尚不证明传输发送 |
| reportSent | 加密消息已交给传输；包含实际消息编号、重传次数、订阅、路径、dataVersion 和白名单标量 |
| transportAck | 收到匹配已发报告消息编号的协议 ACK，可含捎带确认 |
| statusAck | 收到该交换的 Interaction Model StatusResponse，含状态码；成功表示对端协议栈确认，不表示 Aqara 卡片已刷新 |
| protocolFailure、subscriptionClosed、exchangeClosed | 超时/取消/传输错误、订阅移除和交换关闭；首次错误保留最多 64 条同交换/端点的前置上下文到关键历史；同类重复错误的关键归档限频 30 分钟，完整收发仍逐条记录 |
| rpcRequest、rpcResult、commandFailed、commandConfirmed | App 请求与结果、设备操作未获确认；App 内 trace 的操作 UUID 能关联原 LAN 日志 |

报告的 `messageBoundary=true` 行表示一条实际报告消息；同事件下 `messageBoundary=false` 行是它的属性明细，不得逐条当成多个 UDP 包。队列记录不带实际消息编号。Read/Subscribe 结构可记录数字路径与错误码；只有已审核服务的数值/布尔/空值和 Descriptor 数字列表可以导出，字符串名称与安全集群内容始终不导出。原始 matter.js stderr 继续丢弃；没有把其自由文本重定向到日志文件。

适配器固定针对 matter.js 0.18.0，在当前节点实例上包装公开的交换、消息通道与订阅接口，并监听公共属性提交事件；保留原调用、返回/异常和库自有计数器。它不改全局原型、网络策略或重试次数。后续升级该库需重跑协议日志回归。

## 已验证与家庭 Mac 复验

隔离 NetworkSimulator、内存存储和真实 Matter CASE/订阅验证：

1. 先配对离线单灯、保存控制器缓存路径，再重放 54 布局的 UnsupportedCluster；保留两端存储后升级，新版在相同原端点返回 Reachable=true，主/副功能编号、用户名称、fabric 保留，子端点没有 BDBI。持续订阅读到 ConfigurationVersion 变化，Descriptor 正确；同布局重开版本不变。
2. 一次真实 Invoke 仅触发一次模拟原生位置请求，该请求确认失败；随后缓存依次失效、恢复 19%，持续订阅收到实际闭合百分之一 `10000 → null → 8100`、整数百分比 81 和 Reachable 恢复。报告 dataVersion 与库提交及控制器收到的版本一致；订阅/读取/日志没有额外设备 RPC。
3. 在模拟网络丢弃一包报告后得到重传和成功确认；持续丢弃后得到已提交传输但无 ACK、最终超时，控制器未收到该值。日志准确区分这几个阶段。
4. Swift 回归验证类型白名单、非法字段拒绝、脱敏、同文件容量滚动、重开/历史导出，以及受监督模拟子进程的结构化事件进入正式日志入口、stderr 不进入日志。

本机先以完整 Xcode/Node 22 运行 `bash scripts/validate_macos.sh`，可定向运行 `swift test --filter 'MatterDiagnosticTests|MatterJournalIntegrationTests|MatterSnapshotPollingTests|MatterPairingResetTests'`。完成后按用户授权替换，保留两组配对与其他配置，不点击重置。检查：灯具旧/新实体路径实际被 M200 如何访问，Aqara 在线与双路状态；用户安排一次卷帘控制后若卡住，导出相同时间窗，按 C 代号、快照、路径、dataVersion、匿名会话/交换、消息编号与协议确认关联。收到 ACK 仍不等于 UI 更新。没有自动重试硬件控制或额外探针。
