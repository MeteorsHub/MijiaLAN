# ceiling20 主灯与副灯

仅适配 `yeelink.light.ceiling20`。用户已有缓存规格的主服务 2 提供电源、亮度、2700–6500 K 色温与 Day/Night 模式；缺少副灯定义。原导入器跳过依赖 `nl_br` 的亮度模板，导致亮度不可读写，Matter 只能发布开关。本轮不新增 TCP 连接或另一套轮询，继续复用加密 miIO、DeviceController 共享缓存和原调度。

## 依据

- [Yeelight 官方协议](https://www.yeelight.com/download/Yeelight_Inter-Operation_Spec.pdf) 给出 bright、nl_br、active_mode 与 bg_* 的含义，说明日光/夜灯属于主灯、背景灯独立。该文档描述的明文 TCP 入口不直接作为加密 miIO 参数依据。
- 本项目已固定 [hass-xiaomi-miot@75bc74f 的 miio2miot_specs.py](https://github.com/al-one/hass-xiaomi-miot/blob/75bc74f67275bde6a8742b6638039819e10eaea5/custom_components/xiaomi_miot/core/miio2miot_specs.py)：ceiling20→ceiling10→ceiling6，明确旧 miIO 的读写方法、亮度依赖和 nightlight 模式参数。
- 同 revision 的 [miot_specs_extend.json](https://github.com/al-one/hass-xiaomi-miot/blob/75bc74f67275bde6a8742b6638039819e10eaea5/custom_components/xiaomi_miot/core/miot_specs_extend.json) 定义 ceiling20→ceiling4 的 ambient-light 服务 200；Apache-2.0 来源说明保留在 Vendor/hass-xiaomi-miot。
- [小米官方集成 issue #41](https://github.com/XiaoMi/ha_xiaomi_home/issues/41) 维护者确认原规格只有一个 Light，作为规格缺口依据；不视作本机通信或控制已验证。

## 逻辑能力与真实发送

| App/桥接逻辑属性 | 旧 get_prop 名称 | 写入方法与参数 |
|---|---|---|
| 主灯 2.1 电源 | power | set_power ["on" / "off"] |
| 主灯 2.2 亮度 1–100 | bright、nl_br、active_mode，同一批 | set_bright [整数] |
| 主灯 2.3 色温 | ct | set_ct_abx [K,"smooth",500] |
| 主灯 2.4 模式 1 Day / 2 Night | active_mode，原始 0/1 | set_ps ["nightlight","off" / "on"] |
| 副灯 200.201 电源 | bg_power | bg_set_power ["on" / "off"] |
| 副灯 200.202 亮度 1–100 | bg_bright | bg_set_bright [整数] |
| 副灯 200.203 色温 1700–6500 K | bg_ct | bg_set_ct_abx [K,"smooth",500] |
| 副灯 200.204 RGB 整数 1–16777215 | bg_rgb | bg_set_rgb [整数] |

200.* 是本项目的逻辑投影，绝不发送 MIoT get_properties/set_properties。只对确切型号且具有相应主灯属性的缓存规格补充服务；不覆盖已存在的服务 200，不改原缓存文件，不扩展其他型号。副灯色温/RGB 范围按固定来源声明，实机返回不符合范围时保留错误，不伪造数据或全局放宽校验。

主灯亮度使用同次有效 active_mode 判定：0（日光）取有效 bright；1（夜灯）取有效 nl_br。字符串数值先按旧协议归一化，随后严格检查整数和 1–100。日光 nl_br=0 或未提供时仍可取真实 bright；夜灯 nl_br=0、缺失或无效时，不将残留日光亮度当作当前夜灯亮度。模式缺失/无效则亮度不可用。这是对源模板加上模式一致性检查，避免其 default(0) 把坏依赖当成正常数据。模式写入后同批回读模式与主亮度，不等待额外定时器来修正旧模式读数。

App 分主灯、副灯两组，各自开关、亮度滑条、色温；主灯显示日光/夜灯模式，副灯保留 RGB 整数输入。沿用既有连续输入提交与设备队列，拖动后提交，普通刷新不重建控件。调光前若需开灯，只开启相同 SIID 的电源；两路合并键和编辑状态独立。亮度读数错误可见。旧 setter 仅发一次，不因超时/拒绝自动补发，bg_set_* 计入旧协议写日志。

Matter 主灯原逻辑 ID 不变，恢复开关/调光/色温；副灯用稳定 `:light:200` ID，独立开关/调光/色温，同 sourceID 组成单一实体。色温与亮度均绑定到各自 SIID。RGB 在 App 保留，本轮不新增 Matter RGB 映射。普通状态同步只消费缓存。旧单功能→双功能升级保留主灯功能端点编号、UniqueID、自定义名称和 fabric；后续兼容修复让历史主灯端点同时承载唯一实体身份与主功能，只新增副灯子端点；已过中间布局的处理见 [迁移与报告诊断](matter-migration-reporting-diagnostics.md)。不自动重置配对。平台可能缓存旧布局，免重配发现需本地验证。

## 回归与实机边界

Swift 模拟测试使用真实 miIO 加密/解码，检查依赖读集合、类型/缺失/模式切换、App 快照、独立滑条开灯/调光、模式回读、主副灯色温、RGB，以及实际旧方法和参数、拒绝写不重发、无 MIoT 原生方法。matter.js 回归验证双路状态和命令隔离，另用模拟已配对控制器验证旧布局升级后的编号、名称和 fabric 保留。

本轮没有家庭设备读写、安装、重配或开启真实桥接。家庭 Mac 先完整编译/测试与原生界面验收，再由用户安排单台实机：主灯日光亮度、夜灯亮度及模式回读，主灯色温，副灯开关/亮度/色温/RGB，各次核对另一通道未变化；随后检查 M200 新副灯导入及独立控制。缺失值先收集最小只读证据，不靠重复写入尝试恢复。Aqara 自定义功能文案未达目标，见 [命名实测记录](aqara-function-name-findings.md)。
