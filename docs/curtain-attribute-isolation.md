# 卷帘累计属性查询排因：只读工具与证据边界

## 最新现场结果

本地线程报告：2026-11-10 **04:06:14（北京时间）**，44958fa App 的 N 策略在约 **2 小时 49 分钟**、readRound **321** 的完整六项查询再次出现 -4004。四小时长测**提前失败**，后续 socket/layout/hello/stamp 轴测试全部取消，App/CLI 均已退出。此前 CLI 48 轮只能保留为短测通过；N 组合没有通过本次长期实机验收。

本次坏批次的明确值：

| 属性 | code | 实际值/类型 | 验证解释 |
|---|---:|---|---|
| 2.2 电机状态 | 0 | number 1 | 报告的原始值 |
| 2.3 实际位置 | 0 | number 0 | 报告的原始值 |
| 2.4 目标位置 | 0 | number 0 | 报告的原始值 |
| 2.5 反向 | 0 | **number 2** | 应为 boolean；前 37 次完整读取均为 boolean false，此项已损坏 |
| 2.9 故障 | -4004 | 没有报告可用值 | 错误 |
| 2.10 模式 | -4004 | 没有报告可用值 | 错误 |

不能将前四项 code0 一概记为正常。fixture `dooya-overnight-2026-11-10.json` 保存文字转录，不是云端已打开的原始抓包。另有本地真实 CLI/AES 回环重放：保持六项 code 全0，仅将 2.5 改为 number2，N 在 hello/info/read 三包后退出1、完成轮次0、reason=untrustedReading，无第二轮或写入。当前代码的类型 guard 可拦截该异常，不需要放宽。

## 计数口径与候选

本地审计的 **Mac CLI＋隔离 App**：CLI 48 read = 5 full + 43 compact；App 321 read = 33 full + 288 compact，App 前32次 full 成功、第33次失败。合计 **38 full（前37次成功）＋331 compact = 369 read**；hello93 + info2 + read369 = **464 个 Mac 实际发送**，无 write/action/其他方法。2.4/5/9/10 各被这些 Mac 请求选取38次，2.2/3各369次。

**范围不含**重启后的手机基线控制、手机或云端其他通信；它不是全网或设备生命周期的绝对38阈值。首次异常在第38个 Mac 完整查询中被看见，设备内部状态也可能在前一次 full 后就发生了改变。每地址计数反映请求暴露，不等同于已经观察到的固件内部 getter 调用次数。

旧样本重新按 source/stage 拆除两属性确认读取后：无控制的 C1/C5/C6/C7 均第38次 full 失败；C4 的39总 read 中有1次确认 compact，也在第38次 full 失败；C8 的38总 read 中有1次确认 compact，是**第37次 full**失败，另有一次 2.4=21 写入。写入可能影响某个属性级计数只是候选，不能说所有设备都固定第38次。

本次失败仍用同一 client/socket/源端口52201，刚 hello 约5.3秒；RPC ID6629匹配，requestStamp16856/responseStamp16857/helloStamp16851，clockAccepted=true、skew+1，peer/header/auth均通过。整个 App 321 read 的 skew 0/1/2 秒分别124/196/1，拒绝或身份/RPC/auth不匹配均0。读间隔中位31.903秒、最大37.543秒；冷启动第二次约15.05秒，周期hello后的补偿间隔约26秒，未见洪峰或长睡眠空白。

这些数据说明 stable/periodic/helloAnchored 未消除这次故障，优先区分完整合包、某个扩展属性及组合累计效应。9/10 首先报错未定位到具体 getter；2.5 同时类型异常也需保留。**不再仅改间隔来宣称修复。**

## 新入口：curtain-attributes

这是独立 `CurtainAttributeProbe`，**不调用 CurtainControlSession.poll，不发启动 full 或300秒 full**。固定 stable socket / periodic hello / helloAnchored stamp；只支持 `get_properties`、必要 hello 和一次型号/固件 info。无控制方法，无 action，无重试，异常锁存后无法在该实例内恢复。

计划模式不读 stdin、不访问钥匙串、文件或网络：

```sh
.build/debug/mijia-lan curtain-attributes --properties 2.5,2.9 --packet-layout single --phase probe --slot 1 --rounds 48 --interval 30
```

- `--properties` 是全部 get_properties 的**有序**列表，只接受 2.2/3/4/5/9/10 的唯一子集；保留顺序，拒绝重复、空项、其他 SIID/PIID 或方法。
- `--packet-layout batch`：每轮一个包，地址顺序精确等于列表；`single`：每轮按顺序逐项一个RPC。没有自动追加 2.2/3、安全 full、拆包回退或周期 full。
- 轮次1…48；开始间隔5…300秒，单一循环、不补积压。每次普通 RPC 保留5秒最小间隔；single 轮次及周期hello可能拉长实际时间，按日志比较，不把不同布局称为等 UDP 包数。
- 每个 RPC 结束后检查 discarded 锁存，包括错 RPC 后又来了合法回复的情形；**在下一所选属性前停下**。不等整轮结束。任何负/非零 code、缺项、额外项、重复地址、不可信类型/范围、超时、时钟/身份异常均停。
- 只校验所选字段的读值，不用部分值填充产品缓存或合成“可信当前位置”。尤其不能从单独2.3合法范围值推断全设备正常。
- 真正执行还必须显式 `--execute --baseline-normal --log-directory NEW_DIRECTORY`，配置只从 stdin 传入，slot 是这份私有输入的次序。没有环境变量自动启用，不接受 token/IP/DID argv。新日志目录创建0700。
- SIGINT/SIGTERM 取消并关闭 socket；无写入，失败后不发送后置基线或下一组。结果非零退出，安全 `result.json` 保留已完成轮数、原因、错误码及实际发送计数。

当前设备已故障、用户在休息：**今晚只做编译、假数据与回环，不执行上述真实模式，不发新硬件包，不重启/复位。**

## 显式前后 N 基线：分别运行，全部计数

`--phase baseline-before` / `baseline-after` 各是**独立的一次调用**，必须显式指定规范六项列表、batch、rounds1。没有隐藏基线，也没有一键串联多阶段：

```sh
.build/debug/mijia-lan curtain-attributes --properties 2.2,2.3,2.4,2.5,2.9,2.10 --packet-layout batch --phase baseline-before --slot 1 --rounds 1 --interval 30
```

这是只打印计划；需要真实执行时仍需完整 arming。后置仅将 phase 改为 baseline-after，条件相同。它们是固定新通信策略的一次完整校验，不是重启或固件恢复；两次都增加完整/扩展属性暴露。独立调用各自建立新 client/socket，稳定源端口只保证各调用内，跨阶段不能冒称同一会话。被测阶段有异常就不做后置基线，不试图用它恢复。将每个独立 run 的计数逐个纳入同一硬件恢复窗口，同时保留阶段边界，不能只算 probe。

## 日志和实际发送计数

- `traffic.jsonl` scope=experiment，继续完整64 MiB＋关键4 MiB滚动和已有脱敏。
- 本探针 hello/info/read 的 wire 事件增加 `packet.attributePlan`（有序属性/布局/phase/轮数/间隔）、`attributeRound` 与 `attributeExposure`。
- 计数只在实际 `sent` 回调递增，attempt/重复事件不算额外发送。分别含 hello/info/read/write/other、六地址同包数、2/3同包数，以及每个白名单地址的请求次数。拆成六个单属性包时六项各加1，六地址同包数仍为0。
- `result.json.exposure` 和最后一个实际 sent 的计数可与抓到的 UDP 对照。累计仅限当前 probe 实例，**不冒充全设备累计值**；跨 CLI/App/前后基线需按已审计记录另行汇总，注明手机/云端未计数。
- 失败批次仍先完整记录每项 code、类型及安全受限标量再抛错。2.5=number2和9/10=-4004不会丢失，也不被转换成 bool。
- `policy.layout` 在新工具表示固定批量/逐项发送；真正查询集合以 `attributePlan.properties` 和实际 `addresses` 为准，无 adaptive 自动读取。

## 下一轮实验准备（尚未授权执行）

在用户醒来、授权并恢复一台干净正常基线后，才能选择单因素：先比较规范六项 batch 与同序六项 single，再根据结果选择 core2/3、扩展4/5/9/10的单项/子集及顺序。每个候选需要独立可比较的恢复窗口与精确 Mac 暴露记录；同一设备连续串行测多个子集会携带历史，不能直接归因。前后完整基线也可能影响下一阶段，必须计入，不盲发在故障设备上。

48轮 core-only 的阴性结果不能自动等价于本次369次core暴露的对照；批量/逐项的实际UDP包数、每地址次数与时间均须比较。根据离线准备和用户条件再确定具体组，不自动轮换。

## 验证入口

```sh
swift build --product mijia-lan --force-resolved-versions
swift test --filter 'CurtainAttributesTests|CurtainAttributeProbeTests|MiioDiagnosticsTests' --force-resolved-versions
```

云端使用真实 BSD loopback，Linux 编解码仍有替身；真实 AES/MD5、CLI 进程级和 macOS 全量仍需本地验收。回归覆盖有序子集跨300秒无隐藏full、batch/single精确地址计数、逐RPC错包锁存、hello超时零重试、原坏批次与全code0类型损坏、合成37次好full后坏批次停止。合成累计故障模型仅验证工具行为，不是固件根因证明。


本次云端定向 **11 项通过**（新功能/坏批次10项，加旧UDP超时用例定向复查），隔离完整 **142 项通过**，**119 个 Swift 文件语法检查通过**。首次全量执行时旧80ms UDP超时 fixture 的 discarded 断言出现一次并行调度失败；未修改该测试或传输代码，随后定向及完整复查通过。原生真实 AES/MD5 与 CLI 进程级尚待本地，不将 Linux 替身结果算作原生验收。本次未发硬件包、未改自动查询周期或 e57 网络通信算法。
