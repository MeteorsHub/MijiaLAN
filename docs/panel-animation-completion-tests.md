# 面板动画完成与内容卸载测试

`PanelMemoryTests.exitCompletion` 验证退出完成后才启动内容卸载，以及快速重新打开时旧回调失效。旧测试在屏幕外创建真实窗口，依赖 `NSAnimationContext` 完成回调，在部分本机运行中等待五秒仍停在 opening。曾有通过记录；现有证据没有确定系统回调未完成的具体原因。

`PanelPresentation` 现在允许注入窗口动画执行函数，默认仍使用原来的 AppKit alpha 动画、时长、曲线和主线程完成回调。正常 App 的调用不传该参数，显示和退出策略保持原样。

测试用手动执行器按指定顺序完成旧 opening、旧 closing 和新 opening，核对旧回调不能关闭新面板；只有当前退出完成才触发 `didClose` 和内容卸载计时。受控时钟再验证计时结束后卸载。另覆盖 stop 后迟到回调，以及停止后的重新使用。普通和减少动态效果两条配置均检查动画参数。删除测试中的 WindowServer 回调期限和轮询等待，不延长超时或放宽断言。

Linux 检查使用 AppKit/SwiftUI 平台替身，执行实际 `PanelPresentation` 状态代码、`PanelContentLifetime` 和手动回调测试；它只验证回调顺序与生命周期逻辑，不验证原生渲染。Mac 复验：

```sh
swift test --force-resolved-versions --filter 'PanelMemoryTests|PanelToggleTests'
```

随后运行完整 `scripts/validate_macos.sh`。不需启动或替换正式 App，也不操作真实设备。
