# dc1545 / 固件1.1.3：正常读取排除电机反向

本轮交付为**兼容修复候选**。正常 App、手动状态、控制前置和旧验证入口改用 `[2.2,2.3,2.4,2.9,2.10]`，不再请求2.5；控制命令与实际2/3回读不变。只针对已验的 `dooya.motor.dc1545` / 固件1.1.3，其他型号和未验证固件的策略不扩大。

## 现场依据

以下为本地文字报告，云端未读取原始抓包：

- 客厅遮阳 core2/3 ×48、2.4单项 ×48及对应full后检均通过。随后只读2.5，前34包通过、第35包直接-4004；此前3次full均含2.5，故本机第38次2.5请求首次失败，前37次均boolean true。2/3/4当时各51次，9/10各仅3次，full仅3包。身份、RPC及新时钟校验正常，无写入或自行变向；失败后未追加后检。
- 书房2.10单项48次和full后检通过，随后五字段batch48次＋相同五项1包后检全部通过，不含2.5。此时2/3/4/9各51次、10为99次、5为2次，get_properties共99包。
- 之后独立canary只读2.5一次（本窗口第3次），仍boolean false/code0；这包另计，不混入49个五字段包。它有助于排除仅因不查询2.5而看不到其已损坏的解释。
- 主卧2.9第二个单项请求2秒超时，没有-4004，独立恢复补测仍待用户确认。书房五字段中的2.9已有51次成功，不能用一次超时定性其有累计故障。

三台DID/host/token互异由本地仅在内存核对。上述计数限定Mac审计窗口，非设备生命周期绝对阈值。最强证据是2.5单项阶段可复现，而排除5的候选集合和末尾5 canary仍正常；固件内部机制尚未定位。fixture `dooya-five-property-evidence-2026-11-10.json` 保留各阶段边界和bool true/false差异。

## 正常与显式诊断严格分开

- `CurtainReadProfile.normalFive`：初次、周期完整校验、手动、控制前置和旧 `CurtainValidationSession` 都读取五项。普通adaptive仍读取core2/3、按原有10次/300秒界限完整校验；只改变完整集合，不改刷新周期。
- 五项继续严格检查地址唯一/完整、code0、类型、范围、fault=0和身份/固件/时钟。控制前仍要求停止，单次写入、不重试、有限回读；Stop优先级不变。不会删除9或接受其错误。
- `packet.curtainReadProfile` 标记当前配置，实际 `packet.addresses/propertyCount` 是五项或core/确认两项；DEBUG只读App `plan.json` 列出五项及normal-five标记。
- 现有开关、暂停、配置、配对及64MiB完整日志不迁移、不清空。已坏设备不会因换版本自动恢复或解除暂停。
- `curtain-attributes --properties 2.5 ...` 保留显式读取5和严格坏值验证，其基线阶段仍是用户明确指定的历史六项，不悄悄改名。做五项检查使用 `--phase probe` 与五项列表。
- `curtain-experiment` 此版本默认跟随正常五项，计划输出实际集合；只有额外 `--diagnostic-six` 才使用明确标记的六项只读诊断。历史e57/e016的full6数据不改写为full5。
- 旧通用 `diagnose` 的dc1545清单也排除5；其他型号的2.5字段原样保留。通用/桥接绕过路径仍受既有DeviceLANPolicy限制。

## 诊断单次等待预算

`curtain-attributes` 可额外指定 `--rpc-timeout 5`，整数1…30秒，默认2。仅改变该诊断实例一次info/read RPC的等待，不重发、不自动恢复；hello仍2秒，普通App和控制超时保持2秒。plan/result包含 `rpcTimeoutSeconds`，wire日志 `requestTimeoutMilliseconds` 记录每个实际请求的预算。

旧attributePlan日志缺少此字段时按2秒解码，继续可读。single在每个RPC后检查错误/丢包锁存，延长预算也不允许错包后发送下一属性。主卧当前不因新增选项而自动继续查询。

## 本地先做编译与回环

```sh
swift build --product mijia-lan --force-resolved-versions
swift build --product MijiaLANApp --force-resolved-versions
swift test --filter 'CurtainNormalProfileTests|CurtainProbeTimeoutTests|CurtainControlTests|CurtainValidationTests|MiioPolicyTests|CurtainAttributeProbeTests|CurtainAttributesTests|ReadOnlyAppTestTests' --force-resolved-versions
```

重点验收：正常自动/手动/控制前置/旧验证的所有read均无5；其余五项坏code/type/range仍停止且不写；2/3回读及单写保持；manifest/log清楚显示五项；显式选择5仍可读且拒绝number2；诊断3秒回复在2秒默认下失败、显式5秒下成功，5秒无回复只有一个属性发送且不发single下一项。数据均用假种子/回环，现阶段不启动真实App或硬件请求。之后由本地验证结果再确定家庭验收，不能把有限五项探针通过写成修订App实机已修好。


云端候选检查：隔离完整Swift **148 项通过**，**122 个Swift文件语法检查通过**。包括512轮虚拟时间的正常adaptive读取、正常日常及旧验证真实BSD回环各超过48次完整五项、原控制单写与两项回读、五项坏值拒绝、显式坏5重放、三秒延迟与五秒无回复。Linux编解码仍为替身，原生App/CLI、真实AES及实机控制/长测需要本地补齐。旧80ms UDP fixture曾因响应线程晚于截止点才启动而缺少discard事件；仅在fixture的sent边界先排入一个错源包以建立前提，未改80ms预算、断言或传输算法。锁屏动画旧失败仍不在本轮修复范围。
