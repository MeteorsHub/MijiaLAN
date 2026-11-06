# 家庭只读诊断第二轮

第一轮由本地线程使用 397736b CLI 完成，11 台、6 型号均通过 `miIO.info` 型号校验。以下是该线程提供的脱敏报告，不是云端直接连接设备取得的原始报文。仅确认读取，不代表任何写入、Matter 配对或控制已通过。

| 型号 | 固件 / 规格版本 | 已确认读取事实 |
| --- | --- | --- |
| dooya.motor.dc1545（6 台） | 1.1.3 / MCU 0003 / miIO 0.1.0 / URN :1 | 2.2、2.3、2.4、2.5、2.9、2.10 全部逐属性 -4004，无 value；info 成功 |
| xiaomi.pet_waterer.70m2 | 1.0.47_0030 / URN :2 | 2.1 是 boolean true，与 uint8 fault 枚举冲突；2.7=60；2.11=-4001；2.3=1 和 2.10=false 独立 |
| giot.heater.v13daf | 1.1.3 / MCU 0008 / URN :1 | heater 2.1=false，light 3.1=true，heat-level=8，light mode=4 |
| xiaomi.derh.13l | 2.2.2 / MCU 0008 / URN :1 | 3.2=22.1，缓存 float [-30,100,1]；湿度 45、目标湿度 50、电源 true |
| iot.tow_w.jd015 | 1.1.3 / MCU 0054 / URN :1 | 电源 true，status=3 Stop，目标 65、当前 59；开机与运行不是同一含义 |
| xiaomi.feeder.pi2001 | 2.1.9_0139 / URN :3 | 已选的 11 个 2.x 属性均成功；2.29=100，其余为 number 0；5.x 尚未读取 |

`Tests/MijiaLANTests/Fixtures/household-readings-2026-11-06.json` 是上述文字报告的回归转录，日期为接收日期，不是设备时钟或原始抓包时间。除湿机增加只包含已核对温度声明的 v1 测试规格，保留原先公开 v2 投影，不覆盖生产缓存。

## 请求格式核对

已检索该精确型号及常用实现，未找到可核验的 `dooya.motor.dc1545` LAN 专用实现或厂商只读旧命令定义。不能据其他杜亚型号直接套用 `get_prop` 参数名、猜测电机位置或增加写命令回退。

可核验的通用实现使用不同的请求体 DID 表示：

- [python-miio 的单属性查询](https://github.com/rytilahti/python-miio/blob/9a00e0888ef85f8d8d84888cabd9e46d1b0a18df/miio/miot_device.py#L133) 使用 `siid-piid` 形式作为响应关联标识。
- [hass-xiaomi-miot 的本地映射查询](https://github.com/al-one/hass-xiaomi-miot/blob/75bc74f67275bde6a8742b6638039819e10eaea5/custom_components/xiaomi_miot/core/device.py) 支持配置 DID 或 `prop.siid.piid` 别名。
- [小米串口协议的 MIoT 状态码](https://iot.mi.com/new/doc/accesses/direct-access/embedded-development/wifi/module-dev/serial-communication)：-4001 属性不可读，-4002 属性不可写，-4003 属性/方法/事件不存在，-4004 其他内部错误，-4005 属性值错误，-4006 方法输入参数错误，-4007 DID 错误。此前把 -4004 写成“参数错误”的 UI 提示已纠正。

这些通用实现只能支持设计只读对照，不能证明该卷帘认可其中任何一种表示。生产读写寻址保持原策略，Matter 卷帘控制保持未启用。

## 最小下一轮探针

新增显式命令 `mijia-lan diagnose-followup`，仍只接受 stdin，不接受 token、IP 或任意方法参数。只选配置中的第一台该型号卷帘及第一台该型号喂食器，最多两台：

1. 卷帘：标准 hello 获取协议 DID（不输出其值），经 `miIO.info` 再次校验型号；对 2.2 status、2.3 current-position、2.4 target-position 分别使用配置 DID、握手 DID、`2-piid`、`prop.2.piid` 发单属性 `get_properties`。配置 DID 与握手 DID 相同时省略重复项，因此共 9～12 次属性读取。仅报告 `configuredDidMatchesHandshake` 布尔比较、`requestDidForm` 分类、SIID/PIID、code、原始标量值及类型，不输出请求或响应中的真实 DID。
2. 喂食器：经 info 型号校验，仅查询先前报错标题已匹配的 5.3 加餐提醒开关、5.4 计划进度显示开关、5.6 进食量低提醒开关状态。缓存声明均为 bool/read/write/notify；保留返回的 bool 或 number 类型，不自动转换。5.8/5.12/5.14 无需本轮查询；5.1 喂食计划永不加入该探针。

每个探针只发送一次、不重试；错误后保留结果并继续有限白名单。没有 `set_properties`、`action`、`get_prop`、电机控制 2.1、喂食或重置。不会修改 App、配置、缓存或配对，现有 App 可保持运行。

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

若三个位置/状态属性在全部 DID 形式下仍为 -4004，下一步需要厂商对该固件 LAN 只读协议的说明，或能确认此型号的受支持实现/只读日志；不根据猜测扩展旧命令。若某一种形式返回有效位置，先确认 JSON 类型/范围、静止时重复读数以及用户明确标注的现有物理位置，再设计方向、停止和写后回读验收。单次有效位置读数仍不是控制验证。

## 当前兼容行为

- 浮点 22.1 保留；饮水机 true/fault 类型冲突保留原值与错误，不将其显示为无故障。
- 已观察到读取错误的属性仅禁用其对应控制，成功属性继续提供；卷帘只写电机控制在状态/位置未确认时也不接受盲写。控制层和 UI 使用同一判定，健康状态仍独立反映在线连通性。
- 加热、照明、毛巾架温度各自保留原始语义。尚未新增 Matter 卷帘或加热控制，也未声称设备写入或 M200 配对成功。

本轮云端隔离构建执行了 20 项 Swift 逻辑测试（包含原有诊断、规格测试及新增样本回放/DID 对照），均通过。隔离构建保持上游 JSONValue 真实访问级别；真实 UDP/密码学及 macOS App 边界仍使用替身或未执行。新增 `FieldTelemetryLANTests` 需要 macOS 才运行；完整 App/CLI、既有控制回归和打包建议在本地用 `scripts/validate_macos.sh` 再验证，不将这些云端测试称为实机控制验收。
