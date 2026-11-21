# Matter 配对重置

设置 → 管理 Matter 设备与配对 →「重置 Matter 配对…」。确认弹窗说明会断开此桥接的全部 Matter 平台连接，之后需重新添加；继续使用的控制器里可能还有需要另行移除的旧条目。取消确认不调用重置。重新连接仍只是保留配对的进程重启。

重置只处理 `Matter/mijialan/` 内部节点目录，保留同级 `commissioning.json`、米家配置、其他 App 偏好、Matter 设备选择和独立 HomeKit 配对。旧节点原子移动到 `Matter/PairingBackups/<随机目录>/mijialan/`；备份父目录限制为 0700，包含旧配对资料，不导出或打印其内容。重置不更改设备协议映射或轮询，也不发送设备控制。

控制器在整个操作期间阻止普通 reconcile、重复重置和重新连接；保留已经终止但尚未退出的 sidecar 引用。只有所有旧进程确认退出才移动存储。已开启时启动新 sidecar，确认报告未配对且提供有效二维码 URI/数字码；关闭时维持关闭。成功后原设置页显示「等待配对」及二维码、数字码。需要至少一个已选择的可桥接设备才能重置已开启的桥接。

退出超时不会强杀进程或移动原存储。新启动失败、仍有 fabric、配对码无效或操作取消时，先等待新进程退出，再恢复旧节点；新生成的失败节点另存私有目录。若进程始终无法退出或磁盘权限阻止恢复，界面显示原因和旧备份路径，保持停止自动启动。此时先完全退出 App，确认 sidecar 不再运行，再由用户安排将旧备份的 `mijialan/` 恢复到原位置，避免运行进程同时写入。不要用删除整个 Matter 根目录来排查。

现场来源：用户报告 98c1c8f 名称修复不会刷新 Aqara 已导入条目；从 Aqara/iPhone 移除后，本地仍有 Apple fabric，因此仍显示已配对。用户授权本机将节点目录移出、保留 commissioning 后，桥接进入等待配对；再次导入 Aqara 名称正常。本轮实现复用这个作用范围，不推断所有平台缓存的行为。

离线回归以私有临时存储、模拟 fabric 文件和真实 OS 子进程验证成功/失败/取消、退出门槛、回滚、启动未配对和保留设置。模拟 ready 报告不是一次真实 Matter CASE 配对；实际 UI、平台重新配对仍由用户安排。没有新增 App 测试启动模式或环境参数。

Mac 只做构建与离线复验：

```sh
swift test --force-resolved-versions --filter 'MatterPairingResetTests|MatterPlatformTests|MatterSnapshotPollingTests|CurtainInteractionTests'
bash scripts/validate_macos.sh
```

保持正式 App 和已有配对原状，不安装或触发重置。界面验收经授权后核对取消不动数据、重置提示影响范围、成功后的二维码，以及 HomeKit/米家清单/设备选择仍在。分组升级本身不调用此功能。
