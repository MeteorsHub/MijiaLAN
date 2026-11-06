# 家庭设备排查：已确认修正与验收边界

> 此页记录 b1100d9 时的阶段性结果。2026-11-06 已收到第一轮实机读取报告，最新事实、修正和第二轮探针见 [household-followup-diagnostics.md](household-followup-diagnostics.md)。下文“待采集”描述仅适用于当时，不代表最新状态。

本轮基于用户的只读 UI 文字报告、源码及公开规格进行修正；未收到真实属性原始报文。远程运行 App 的 SHA-256 已由本地线程确认与 262a540 构建一致；卷帘缓存 URN 已确认是 `urn:miot-spec-v2:device:motor-controller:0000A01D:dooya-dc1545:1`。其他型号的实际固件/规格版本仍待只读诊断，不将测试 fixture 当作实机证据。

已修正：

- 浮点传感器读取不再要求符合写入步长，仍严格检查 JSON 数字类型、有限值、范围和枚举；整数读数及所有写入仍保留步长限制。比如规格为 float、step 1 的温度可以保留 24.5，而不是报参数错误。是否解释实际除湿机故障，需与原始读数核对。
- 同一服务的同名属性优先保留规格中的说明，并附 `S<SIID>/P<PIID>` 标识。饮水机 2.7/2.11、喂食器多个 status 不再只显示一个无法区分的标题；不删除或合并属性，也不擅自推断两种出水间隔的适用固件。
- 壁炉 heater 主电源与 light 灯光电源使用不同标题，主开关继续绑定 heater 的 2.1。
- 已确认型号中故障枚举标签为字面量 `null` 时，数值 0 显示“状态码 0（规格未提供说明）”。不将真实 JSON null、无值或返回错误显示成正常状态。
- 补充 Normal、MaxSchedule、Left-gram-display 等选项的中文显示。

测试规格见 `Tests/MijiaLANTests/Fixtures/README.md`。这些是注明来源和版本的部分规格投影，仅打包到测试 target，不替换生产缓存，不增加自动控制或改变配对身份。

本地复测：

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter FieldSpecificationTests --force-resolved-versions
```

保持旧 App 可继续运行。先使用单独编译的 CLI 按 `read-only-device-diagnostics.md` 采集脱敏诊断；不要为了 UI 复测启用桥接、配对或触发设备动作。新 App 的上述 UI 显示可在用户方便时单独复核。

仍未解决/验收：

- 卷帘 -4004、饮水机 -4001，以及喂食器厂商布尔属性的真实返回类型尚待诊断；没有增加未经确认的旧 miIO 命令回退。
- Matter WindowCovering 位置方向、停止和状态回读；除湿开关/目标湿度/模式；毛巾架加热电源/目标温度；壁炉独立控制映射仍待开发与验证。本轮没有新增这些控制映射。
- 当前 Matter 桥接未实现饮水机或喂食器的专用语义；喂食是一次性动作，不暴露为可自动重试的开关。原生 App 的喂食动作同样保持未支持。
- 当前毛巾架温度是设备温度，不能据此认定是房间温度；壁炉档位也没有被当作恒温目标温度。
- 所有真实控制、桥接配对、状态同步和 Aqara M200 兼容性仍待家庭环境实测。
