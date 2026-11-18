# Matter 实体设备分组

同一台米家设备的开关、照明、温湿度现在按稳定 `sourceID` 分组。Swift 的 Entry 原有 sourceID 继续作为选择依据，并把 sourceID/sourceName 明确放入发给 sidecar 的设备快照。逻辑功能 did 保持原样，用于原有写入路由；不通过拆分 did 字符串猜实体。

## 端点结构

单功能设备沿用原端点：应用设备类型、功能 Cluster 和 Bridged Device Basic Information 在同一端点，PartsList 为空。

多功能设备使用 matter.js 0.18.0 的 BridgedNodeEndpoint 组合结构：顶层仅承载一个实体身份；所有应用功能（包括主电源）放在子端点。顶层 Descriptor PartsList 列出各子端点；功能子端点不再有 Bridged Device Basic Information。这样避免多项功能各自被公布为独立的桥接实体，并遵守库的 Separate Endpoints 组合模型。Aqara 是否以单条实体、嵌套功能或其他形式呈现，仍需实测。

| 实体 | 顶层 | 功能子端点 |
|---|---|---|
| 壁炉 | 一个 Bridged Node，原始米家名称与实体 UniqueID | 加热电源、独立照明，各自 OnOff |
| 除湿机 | 一个 Bridged Node | 电源、Temperature Measurement、Relative Humidity Measurement |
| 只有温湿度的设备 | 一个 Bridged Node | 温度、湿度；不虚构主电源 |
| 单功能灯/插座/卷帘 | 沿用一个身份和应用端点 | 无额外子端点 |

顶层名称继续使用 UTF-8 字节安全的 NodeLabel/ProductName/ProductLabel。正常同步只更新可达性和功能状态，不覆盖用户自定义 NodeLabel。至少一个功能有效时实体可达；每个功能仍单独检查有效性。坏传感器使用未知读数，坏执行器保留最后状态并拒绝命令，不会借其他功能可达而发出未验证控制。尚无历史值的非空属性采用 Cluster 缺省值，平台显示不能当成一次已确认读数。

控制仍发送原逻辑 did。例如壁炉电源用原 did，灯光用 `did:light:<siid>`，由原 MatterDevicePlan 绑定到各自的 MIoT 属性，绝不交叉替代。组合本身不新增 LAN 查询、改轮询、改变协议或调用配对重置。

功能端点另提供 FixedLabel 与 Descriptor.TagList 名称，父端点仍保留整台设备名称；详见 [功能标签与 Aqara 验收](matter-function-labels.md)。

## 旧存储升级

使用 matter.js 公开的 ServerNodeStore/ServerEndpointStores 接口读取已分配端点编号。在组合子端点迁到新父端点下时预设原应用端点编号，让库保留它；不直接编辑存储文件。顶层组合端点是新增端点，因此有新编号。已经组成组合的实体即使日后只剩一个功能，仍保留组合父端点，避免布局反复变化。

有原主端点的实体沿用其 sourceID 哈希 UniqueID，并迁移自定义 NodeLabel。没有原主端点的传感器组合获得基于实体 sourceID 的唯一身份；原来的多个传感器身份收敛为一个，不能同时保留多个顶层 UniqueID。子端点不再独立宣称身份。现有单功能设备的编号、UniqueID 和名称保持原布局。

升级保留 fabric、根节点、commissioning 文件和 Matter 设备选择。测试用临时旧布局存储验证应用端点编号、自定义名和其他节点存储保留；模拟存储哨兵不代表做过真实 CASE 配对迁移。没有重置或重建用户正式配对。

控制器可能缓存旧的扁平端点、名称和自动化引用。保留应用编号有利于保留控制路径，但不能保证 Aqara 自动把旧条目归并；可能需要用户安排重新导入，并核对或重建有关自动化。需要彻底重新配对时，只有用户确认「重置 Matter 配对…」才清除当前节点资料；该操作创建新节点，编号可能重新分配。

## 验证与家庭 M200 验收要点

云端：Node 22 使用真实 matter.js 端点、模拟设备和私有临时存储，验证父 PartsList、子端点无 Basic Information、壁炉两路 OnOff 独立、除湿机 21.5℃/49% 的模拟读数、状态推送零控制、无效功能不写入、单功能兼容，以及扁平→组合→重开/功能减少的存储升级。Swift 模拟回归另验证 sourceID 传递、隐私字段、整台设备选择，以及最终 2.1/3.1 属性写入路由。

本地先只编译、测试和打包，保持当前正式 App 与刚配好的 Aqara 原状：

```sh
swift test --force-resolved-versions --filter 'MatterPairingResetTests|MatterAppliancePlanTests|MatterRPCTests|MatterPlatformTests|MatterSnapshotPollingTests|CurtainInteractionTests'
bash scripts/validate_macos.sh
```

后续由用户安排升级验收：

1. 检查 M200/Aqara 中壁炉和除湿机的实体条目及功能层次，先记录旧条目和自动化；不预先触发重置。
2. 经授权分别操作壁炉加热和灯光，核对命令、回读与实物各自独立；观察除湿机电源及实际温湿度。上文数字只是模拟输入。
3. 检查单功能灯/插座/卷帘、设备名称、原设备选择与持续状态更新。普通刷新仍用共享缓存，卷帘 2.5 继续排除。
4. 若平台缓存未更新，再由用户决定重新导入或显式重置；核对所有仍使用的控制器和自动化。不要将模拟结构通过写成 Aqara 呈现或物理动作已经通过。
