# Matter 功能端点标签

**实测更新：07c842c 在用户 Aqara 重配后，仍显示通用类型名称。标签的协议可读性已验证，Aqara 的自定义功能名称显示目标未达成。官方资料核查、手动入口边界和现场清单见 [命名实测记录](aqara-function-name-findings.md)。**

用户在 Aqara 的壁炉组合卡片中看到两项都叫「开关」。原实现只提供实体名称，功能子端点没有可读取的功能名称。本次补充只读标签，保留实体名称、分组、控制属性、端点编号与现有配对。

Swift `MatterDevicePlan.Device.functionLabel` 按已映射能力生成简短中英文名称。真实加热服务的电源为「加热电源」，独立 light 服务为「照明」，普通电源为「电源」；其他功能使用「温度」「湿度」「加热温控」「缺水状态」「缺粮状态」等名称。不从家庭设备名猜加热语义。

每个功能端点提供两种元数据：

- **Fixed Label（0x0040）的 LabelList**：`function` 为功能名称，`channel` 为实体内功能按稳定逻辑 ID 排序的序号。字段最多 16 UTF-8 字节，截断不拆字符。服务只读；实体父端点不添加功能标签。
- **Descriptor 的 TagList**：启用 TagList 特性。标准 CommonNumber 命名空间 7 的标签表示通道序号 1–30；同时用桥已有的开发 Vendor ID 0xfff1、厂家命名空间 1，提供固定功能类别编号与最多 64 字节的名称 Label。厂家标签附有对应的标准编号标签，不把普通功能名伪装成标准方向、位置或空调语义。超过 30 路的功能仍有 FixedLabel，不发布超范围标准编号或只有厂家标签的 TagList。

序号用于区分当前功能通道，增删功能可能重排，不参与控制路由、端点 ID、端点编号或 UniqueID。标签不定义 Boolean State 的 true/false 文案，也不把功能子端点重新声明为独立桥接实体。当前标签使用 App 语言，在桥接启动时生成；旧快照缺少 functionLabel 时，按已有功能类型提供英文名称。普通状态同步不修改标签或名称，也不发送控制。

父端点的 NodeLabel/ProductName/ProductLabel 继续使用设备名称，保留已存自定义 NodeLabel。升级保留原 sourceID、父子端点 ID 与编号、网络、fabric 和 commissioning 存储，不调用配对重置。

## 回归与本地验收

Node 22 回归覆盖壁炉两路、除湿机三路、只读宠物状态、单功能兼容、UTF-8 长度、通道编号边界与独立写入路由。Swift 回归覆盖服务语义产生名称，以及新增字段的隐私投影。

协议升级测试从没有功能标签的旧组合布局开始，先完成一次模拟 Matter 配对，再保留两端存储重开桥接和控制器。检查 fabric、自定义壁炉名、父子端点编号，通过 CASE 读取两类标签，并确认远程写入 FixedLabel 返回 UnsupportedWrite、无设备 RPC。网络为 NetworkSimulator，存储为内存，不接触正式 App 或实物。

本地先用 Node 22 运行 `npm test --prefix MatterBridge`，再运行 `bash scripts/validate_macos.sh`。安装与启动由本地按用户安排完成，保留当前 M200 配对，不预先移除设备或重置配对。

上述最初的显示验收已有现场结果：07c842c 重配后仍显示通用名称，详见文首实测更新。后续保留现有配对核对协议数据与平台入口，不重复承诺标签生效，也不默认再重配。
