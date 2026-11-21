# Aqara 功能名称实测与去重

收到本地反馈：安装 07c842c 后，用户在 Aqara 重新连接/重新配对，第一次导入仍使用通用功能文案。该结果覆盖此前仅模拟协议可读、尚未验证 App 呈现的边界。

| 实体 | Aqara 实际显示 |
|---|---|
| 壁炉 | 插座1、开关2，对应加热电源、照明 |
| 喂食器、饮水机 | 开关传感器，对应缺粮、缺水 |
| 除湿机 | 插座、湿度传感器、温度传感器 |
| 卷帘 | 窗帘 |
| 吸顶灯 | 开关 |
| 电热毛巾架 | 温控器、温度传感器；二者当前温度都来自 MIoT 2.6 |

这些是用户/本地线程的现场记录；云端没有访问其 App、配对或设备。「插座1/开关2」与标签中的通道序号吻合，但尚无受控 A/B 或平台读取追踪，无法判定序号来自 TagList 还是平台默认命名。可以确认的是自定义功能文字未按目标显示。

## 公开资料核查

2026-11-18 核对官方页面：

- [Aqara 物模型标签](https://docs.aqara.com/zh/docs/aqara-developer/aqara-data-model-specification/aqara-data-model-tags/) 定义的是 Aqara Spec 的 Function/Trait 业务语义。EndpointLabel/EndpointName 不能直接当作第三方 Matter 的同名 Cluster/Attribute；其中设备名称的 NodeLabel/ProductName 规则描述整机名称，并不建立组合子端点 FixedLabel/TagList.Label 的显示保证。
- [通过 Trait 控制设备](https://docs.aqara.com/zh/docs/aqara-developer/aiot-api/execute-device-trait/) 公开 Aqara 侧 `/devices/trait/execute` 的 EndpointLabel/EndpointName 改名；[点位改名](https://docs.aqara.com/zh/docs/aqara-developer/data-export-api/update-device-point-name/) 是 Studio API。它们需要对应平台、权限和模型支持，不是桥发送一个标准 Matter 字段就能执行。本轮未调用这些接口。
- [Aqara 官方 S1 Plus 页面](https://www.aqara.com/eu/product/panel-hub-s1-plus-desktop-version/) 的改名说明确认：设备名和图标在 Aqara Home 中设备自身的设置页编辑。这只支持整机改名的一般位置；**当前 M200/Aqara Home 对第三方组合子功能的准确手动改名入口仍未确认**。不把整机改名或 Studio API 写成已验证的子功能 UI 路径。

结论：现有标签是协议可读的元数据，当前现场已证明它们没有得到预期的 Aqara 功能文案。公开官方资料中未找到可验证的桥接端补写方法，能在保留组合实体的同时强制该版本 Aqara 使用这些功能名。保留标签供支持它们的控制器使用；不增加无依据的厂商字段、不在子端点重复挂实体身份，也不再承诺标签或重新配对必然改名。

## 毛巾架重复温度修复

MatterDevicePlan 按 MIoT 属性绑定 ID（SIID/PIID）检查已发布属性。温控器已经绑定 2.6 时，跳过相同来源的独立 `:temperature`；其他服务或同服务不同 PIID 的独立测温属性继续发布。除湿机温湿度、宠物短缺状态与其他控制不变，不按数值或标题去重。

已有组合实体即使只剩温控器，也保留原父端点。剩余温控器编号、父端点编号、sourceID/UniqueID、自定义名称、网络与 fabric 不变；只是 Descriptor 不再列出旧重复子端点。模拟控制器通过原 fabric 重连后可读到这个变化。

Aqara 是否及时移除旧温度卡片仍需本地检查。平台可能缓存已删除子端点或保留关联自动化；先保留配对查看新版端点清单和卡片，不自动重置、不把删除整台设备当默认步骤。若残留卡片，反馈 App/网关版本和可见管理入口，再由用户决定处理方式。
