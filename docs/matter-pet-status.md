# 宠物设备只读短缺状态

只为下列经过缓存规格与实机只读样本核对的来源增加状态。用户已报告 M200 重新配对后，上一版实体分组正常；此次升级保留该配对，供验证新增端点能否被平台自动导入。

| 型号 | MIoT 来源 | 严格输入 | Matter 输出 |
|---|---|---|---|
| xiaomi.pet_waterer.70m2 | pet-drinking-fountain / 2.10 water-shortage-status | Boolean false / true | waterShortage：false 正常、true 缺水 |
| xiaomi.feeder.pi2001 | pet-feeder / 2.6 pet-food-left-level | uint8 枚举 0 Normal / 1 Low | foodShortage：false 正常、true 缺粮 |

输入匹配精确型号、服务、SIID/PIID、属性名、类型和读取权限；喂食器还要求声明 0/1 枚举。不会从 2.31、故障、模式、厂商数值/布尔冲突字段推导。已报告的 false 与 0 只证明对应采样时刻正常；回归使用模拟 false/true、0/1，不补造当前家庭读数。

Swift `MatterDevicePlan` 仅投影已有 `DeviceController` 共享缓存；普通刷新沿用统一前台 5 秒、后台 30 秒及自定义间隔。Matter 快照不触发即时读取，也不增加独立轮询。缺失值、属性错误、类型/枚举冲突和非在线健康状态均不可用。新增两项还要求有效更新时间：App 时效上限为 max(120 秒, 3×前后台设置中的较长间隔)，独立 CLI 默认 120 秒；缺少时间、超出上限或未来时间均不可用。这个投影检查只影响新增两项，慢轮次超过该上限时暂不可达，下一次有效普通读取恢复。

两项都是 On/Off Sensor 设备类型 0x0850，加只读 Boolean State 服务 0x0045；没有可控 OnOff 服务器 0x0006。true 始终表示短缺。状态失效时 Bridged Device Basic Information 的 Reachable 为 false，保留最后状态而不合成 false；首次没有有效缓存时 Boolean State 的库初值也不能作为可信正常读数，必须结合不可达状态解释。原生执行入口额外拒绝这两个状态的任何写入，即使将来缓存规格误宣称可写，也不会发送设备命令。

逻辑 ID 为原 sourceID 加 `:waterShortage` / `:foodShortage`，实体身份仍为原 sourceID 的稳定哈希。当前每台只有此一项映射，沿用单功能带身份端点；名称沿用原米家设备名，能力说明列出缺水/缺粮。继续复用物理设备选择与分组逻辑。已有选择、功能、网络设置、端点号、根节点、fabric 和 commissioning 存储均保留；新端点按原节点分配并在后续重开时保留编号。不会调用配对重置。

## 离线验证

- Swift 回归检查精确地址/语义、类型与枚举、缓存时效/错误/离线、来源与隐私、正常值/短缺值，以及原生写屏障。App 回归由普通设备刷新填充模拟缓存，随后反复快照、拒绝写入均不新增通信；现有物理设备选择继续有效。
- matter.js 回归检查 0x0850、服务列表、独立状态同步、未知状态不可达，以及已有分组布局增加两项后旧编号/名称和新编号稳定。
- 协议测试使用独立根 Environment、NetworkSimulator 和内存存储，只与模拟控制器通信：先完成一次真实 Matter 配对，再保留两端存储、关闭两端、给桥增加两项并重开；原控制器从已有配对通过 CASE 重连，读取根和 Aggregator 的 Descriptor.PartsList、新设备类型/服务及状态，订阅收到缺水变化，缺粮保持 false。远程写入 Boolean State 被拒绝，无设备 RPC；fabric 元数据保持一致。测试没有重新配对，也没有覆盖持续在线的旧控制器自动发现。网络和存储模拟不等于 Aqara M200 自动导入验收。

## 家庭 Mac 验收

先在干净 checkout 用完整 Xcode 与 Node 22 构建、执行 `bash scripts/validate_macos.sh`。安装/换包由本地线程按用户授权安排；保留当前 Matter 配对，不移除 Aqara 条目、不调用配对重置。

1. 确认原设备选择、分组、名称和既有平台连接仍在，新增饮水机与喂食器两项可选且只列出状态。
2. 记录升级前后的平台设备清单，观察 Aqara 在现有配对下是否自动出现两项 On/Off Sensor；缺水/缺粮真值含义核对平台实际显示。
3. 利用普通共享缓存与已有日志核对读数有效/无效时的展示及同步。不要为验证状态而自动操作出水、喂食或改变真实设备条件。
4. 若平台未导入，保留日志与配对，记录结果后再决定后续动作；此次目标是免重配验证，不能用重新配对成功替代它。
