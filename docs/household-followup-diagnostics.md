# 家庭只读诊断第二轮结果与后续边界

第一轮由本地线程使用 397736b CLI 完成，11 台、6 型号均通过 `miIO.info` 型号校验。以下是该线程提供的脱敏报告，不是云端直接连接设备取得的原始报文。仅确认读取，不代表任何写入、Matter 配对或控制已通过。

| 型号 | 固件 / 规格版本 | 已确认读取事实 |
| --- | --- | --- |
| dooya.motor.dc1545（6 台） | 1.1.3 / MCU 0003 / miIO 0.1.0 / URN :1 | 2.2、2.3、2.4、2.5、2.9、2.10 全部逐属性 -4004，无 value；info 成功 |
| xiaomi.pet_waterer.70m2 | 1.0.47_0030 / URN :2 | 2.1 是 boolean true，与 uint8 fault 枚举冲突；2.7=60；2.11=-4001；2.3=1 和 2.10=false 独立 |
| giot.heater.v13daf | 1.1.3 / MCU 0008 / URN :1 | heater 2.1=false，light 3.1=true，heat-level=8，light mode=4 |
| xiaomi.derh.13l | 2.2.2 / MCU 0008 / URN :1 | 3.2=22.1，缓存 float [-30,100,1]；湿度 45、目标湿度 50、电源 true |
| iot.tow_w.jd015 | 1.1.3 / MCU 0054 / URN :1 | 电源 true，status=3 Stop，目标 65、当前 59；开机与运行不是同一含义 |
| xiaomi.feeder.pi2001 | 2.1.9_0139 / URN :3 | 已选的 11 个 2.x 属性均成功；2.29=100，其余为 number 0；5.3/5.4/5.6 第二轮已读取（见下文） |

`Tests/MijiaLANTests/Fixtures/household-readings-2026-11-06.json` 是上述文字报告的回归转录，日期为接收日期，不是设备时钟或原始抓包时间。除湿机增加只包含已核对温度声明的 v1 测试规格，保留原先公开 v2 投影，不覆盖生产缓存。


## 第二轮实测结果（已完成）

本地线程 `01a1b156-dd7f-7873-88dc-943821f74830` 报告使用 b610a642189c3e2165186fb10220ca340ebcf23d 的 `diagnose-followup` 完成两台设备只读查询，两台均通过 info 型号核验：

- 卷帘：配置 DID 与握手 DID 一致；2.2、2.3、2.4 各用配置 DID、`2-piid`、`prop.2.piid` 读取一次，共 9 次，全部 code=-4004，无状态/位置值。没有发现成功的 DID 写法；握手 DID 因一致而未重复查询。
- 喂食器：5.3、5.4、5.6 均 code=0，原始值均为 JSON number 0，而缓存声明为 bool。读取成功和类型正确是两回事：原值、code 和类型冲突保留，不自动解释成 false，也不推断其写入编码。
- 本轮没有写入、电机动作、喂食或配对验证。

回归转录：`Tests/MijiaLANTests/Fixtures/household-followup-readings-2026-11-06.json`。规格投影补入上述三个厂商属性，保留 bool/read/write/notify 声明。喂食 action 的输入地址投影同时按[小米官方说明](https://github.com/XiaoMi/ha_xiaomi_home/wiki/Feed%2C-start-cooking%2C-play-text-and-execute-text-directive)校正为 2.8；动作继续未支持，没有增加控制入口。

## 隔离观察已完成，继续暂停现场操作

用户随后报告：六台卷帘在米家均在线，但米家发出的控制无反应；实体遥控器可以驱动卷帘，且米家显示的状态随之正确变化。这是用户观察，不是云端直接检查的日志或协议结论。它表明电机动作和状态上报链路至少能够工作，问题范围包含米家控制路径，不能只归因于 MijiaLAN 的适配，也不能排除并发轮询、设备固件或其他控制链路因素。

本地线程 `01a1b156-dd7f-7873-88dc-943821f74830` 随后完成一次隔离观察并反馈如下。以下为本地核验和用户反馈的记录，云端未直接查看进程、手机界面或卷帘动作：

| 阶段 | 本地确认或用户观察 |
| --- | --- |
| 退出前 | 主进程路径 `/Applications/MijiaLAN.app/Contents/MacOS/MijiaLAN`，PID 29801；原先占用 UDP 5540 的 Node 进程 PID 30017。尝试打开设置时误触发了一次局域网扫描。 |
| 正常退出 | 通过应用菜单“退出米家局域网桥”正常退出，保留配置与配对。确认主进程、上述 Node 进程和诊断 CLI 均未运行后开始隔离计时。 |
| 约 30 秒后 | 再次确认上述进程均未运行。退出后的隔离期没有发送设备查询或控制命令。 |
| 手机单次调整 | 本地线程记录用户在手机米家对一台卷帘做了一次小幅位置调整。用户后续澄清：手机控制无反应，未驱动卷帘移动。此操作由用户在米家执行，不是 MijiaLAN 发出的指令。 |
| 实体遥控与状态（用户澄清） | 实体遥控器能够驱动卷帘实际移动；实体动作后，手机米家显示的卷帘状态能正确更新。具体状态字段、数值及实体遥控动作次数未提供。状态更新关联于实体动作，不是手机指令成功的证据。 |
| 手机测试后 | 再次确认主进程、上述 Node 进程和诊断 CLI 均未运行；MijiaLAN 保持退出，现有配置和配对保留。 |

**用户澄清后的观察：停用 MijiaLAN 后，手机米家的单次控制未驱动被测试卷帘；实体遥控器可驱动卷帘，实体动作后米家状态能正确更新。** 先前“卷帘没移动，米家状态有变化”的转述按此澄清解释，不再记为手机指令导致的界面变化。物理动作与米家状态更新的关联来自用户观察，不是云端抓包或属性测量；没有具体字段/数值，不能据此确认手机指令生效或手机设定目标已经到达。

本地隔离步骤只记录了一台卷帘的一次手机调整；实体遥控动作次数未提供，不能补记为额外的单次受控试验，也不能外推为六台设备的完整隔离验收。退出前发生过扫描，不能把退出前后的整段操作描述成“全程没有扫描或请求”；静默隔离期从确认进程结束后开始。约 30 秒观察窗口不能排除较早活动的延迟影响，也不能据此确认或否定故障根因。

用户此后自行对卷帘断电重启，并报告 App 恢复控制；经追问确认，**恢复的是手机米家，MijiaLAN 仍保持退出**。这条恢复观察补充在上述单次隔离结果之后，不覆盖此前手机指令无反应的记录。用户未提供重启覆盖的设备台数、恢复控制的次数或具体位置数值，不能扩展为六台卷帘的完整验收。

断电重启后手机米家恢复，支持当时存在可被重启解除的设备或通信状态异常；具体触发因素仍未确定。这不是新的 LAN 属性读数，没有验证 `get_properties` 是否恢复、位置方向或 MijiaLAN 写入，也没有验证 HomeKit/Matter 桥接或 M200 配对。原先九次 -4004 的回归样本保持原样，不据此改成成功读数。

当前保持 MijiaLAN 退出，继续暂停设备查询和控制测试。先不安排重复测试、重置、重新配网或固件升级。

后续证据要求：

- 卷帘：上述单次退出观察已经完成，目前仍未确认故障根因；后续研究限定于该精确型号/固件可核验的 LAN 只读说明或实现，不安排新的现场操作。现有 9 次 -4004 不能证明所有 LAN 协议不可用，也不能作为任何写入已验证的依据。继续禁用盲写和未验证的 Matter 覆盖物映射。
- 喂食器：仍需该固件对 5.3/5.4/5.6 数值编码的厂商说明，或可核验实现/已有只读样本与米家显示的关联。单独一个 0 不能区分关闭、占位或其他语义，不为采集 1 而切换设置或触发动作。JSON bool 的写入声明也不能证明实际写入应改成 number。

以下命令说明保留为第二轮已执行流程的记录，当前不安排重跑。

## 请求格式核对

已检索该精确型号及常用实现，未找到可核验的 `dooya.motor.dc1545` LAN 专用实现或厂商只读旧命令定义。不能据其他杜亚型号直接套用 `get_prop` 参数名、猜测电机位置或增加写命令回退。

可核验的通用实现使用不同的请求体 DID 表示：

- [python-miio 的单属性查询](https://github.com/rytilahti/python-miio/blob/9a00e0888ef85f8d8d84888cabd9e46d1b0a18df/miio/miot_device.py#L133) 使用 `siid-piid` 形式作为响应关联标识。
- [hass-xiaomi-miot 的本地映射查询](https://github.com/al-one/hass-xiaomi-miot/blob/75bc74f67275bde6a8742b6638039819e10eaea5/custom_components/xiaomi_miot/core/device.py) 支持配置 DID 或 `prop.siid.piid` 别名。
- [小米串口协议的 MIoT 状态码](https://iot.mi.com/new/doc/accesses/direct-access/embedded-development/wifi/module-dev/serial-communication)：-4001 属性不可读，-4002 属性不可写，-4003 属性/方法/事件不存在，-4004 其他内部错误，-4005 属性值错误，-4006 方法输入参数错误，-4007 DID 错误。此前把 -4004 写成“参数错误”的 UI 提示已纠正。

这些通用实现只能支持设计只读对照，不能证明该卷帘认可其中任何一种表示。生产读写寻址保持原策略，Matter 卷帘控制保持未启用。

## 第二轮探针定义（已完成，当前不重跑）

新增显式命令 `mijia-lan diagnose-followup`，仍只接受 stdin，不接受 token、IP 或任意方法参数。只选配置中的第一台该型号卷帘及第一台该型号喂食器，最多两台：

1. 卷帘：标准 hello 获取协议 DID（不输出其值），经 `miIO.info` 再次校验型号；对 2.2 status、2.3 current-position、2.4 target-position 分别使用配置 DID、握手 DID、`2-piid`、`prop.2.piid` 发单属性 `get_properties`。配置 DID 与握手 DID 相同时省略重复项，因此共 9～12 次属性读取。仅报告 `configuredDidMatchesHandshake` 布尔比较、`requestDidForm` 分类、SIID/PIID、code、原始标量值及类型，不输出请求或响应中的真实 DID。
2. 喂食器：经 info 型号校验，仅查询先前报错标题已匹配的 5.3 加餐提醒开关、5.4 计划进度显示开关、5.6 进食量低提醒开关状态。缓存声明均为 bool/read/write/notify；保留返回的 bool 或 number 类型，不自动转换。5.8/5.12/5.14 无需本轮查询；5.1 喂食计划永不加入该探针。

每个探针只发送一次、不重试；错误后保留结果并继续有限白名单。没有 `set_properties`、`action`、`get_prop`、电机控制 2.1、喂食或重置。不会修改 App、配置、缓存或配对，不要求重启 App；当前隔离阶段仍保持 MijiaLAN 退出。

先拉取该分支最新提交并构建、测试：

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --product mijia-lan --force-resolved-versions
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ReadOnlyDiagnosticsTests --force-resolved-versions
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FieldTelemetry --force-resolved-versions
```

已有私有配置时，直接将其重定向到该命令；没有清单时，可使用此前已授权的同一钥匙串管道。不要单独执行 `security ... -w` 显示凭据，也不要使用 tee 或 set -x：

```sh
set -o pipefail
umask 077
diagnostic_dir=$(mktemp -d "${TMPDIR:-/tmp}/mijialan-followup.XXXXXX")
security find-generic-password -s com.mijialan.MijiaLAN -a secrets -w |
  python3 -c 'import sys,json,base64; data=json.load(sys.stdin); sys.stdout.buffer.write(base64.b64decode(data["home_config_v1"], validate=True))' |
  .build/debug/mijia-lan diagnose-followup > "$diagnostic_dir/report.json"
```

钥匙串访问失败时停止，不改 ACL、不重置条目、不导出其他凭据。检查最后的脱敏报告后反馈 JSON；不要反馈原始配置或整个钥匙串。

三个状态/位置属性在已测试的全部 DID 形式下均为 -4004。下一步需要厂商对该固件 LAN 只读协议的说明，或能确认此型号的受支持实现/只读日志；不根据猜测扩展旧命令。若某一种形式返回有效位置，先确认 JSON 类型/范围、静止时重复读数以及用户明确标注的现有物理位置，再设计方向、停止和写后回读验收。单次有效位置读数仍不是控制验证。

## 当前兼容行为

- 浮点 22.1 保留；饮水机 true/fault 类型冲突保留原值与错误，不将其显示为无故障。
- 已观察到读取错误的属性仅禁用其对应控制，成功属性继续提供；卷帘只写电机控制在状态/位置未确认时也不接受盲写。控制层和 UI 使用同一判定，健康状态仍独立反映在线连通性。
- 加热、照明、毛巾架温度各自保留原始语义。尚未新增 Matter 卷帘或加热控制，也未声称设备写入或 M200 配对成功。

本轮云端隔离构建执行了 20 项 Swift 逻辑测试（包含原有诊断、规格测试及新增样本回放/DID 对照），均通过。隔离构建保持上游 JSONValue 真实访问级别；真实 UDP/密码学及 macOS App 边界仍使用替身或未执行。新增 `FieldTelemetryLANTests` 需要 macOS 才运行；完整 App/CLI、既有控制回归和打包建议在本地用 `scripts/validate_macos.sh` 再验证，不将这些云端测试称为实机控制验收。

第二轮结果入库后，云端隔离构建的 22 项逻辑测试通过，新增断言保留九次 -4004 和三个 number 0/type mismatch。本次仅修改测试规格、回归样本和记录；没有变更生产寻址、类型映射或新增设备查询。macOS 完整构建及 LAN 集成测试仍由本地验证，隔离观察已完成，当前继续暂停现场操作。
