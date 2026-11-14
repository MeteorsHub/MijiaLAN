# Swift 6.1 CI 入口文件兼容

GitHub Actions 运行 `43566926415` 已取得 macOS 15 arm64 runner，实际使用 Apple Swift 6.1.2。CLI 编译失败在 `Sources/mijia-lan/main.swift:17`：`'main' attribute cannot be used in a module that contains top-level code`。Matter 作业成功，尚未执行 App 编译或 Swift 测试；此次不是排队取消或设备问题。

CLI 使用 `@main struct MijiaLANCommand`，将文件重命名为 `MijiaLANCommand.swift`，避免 `main.swift` 隐式脚本入口与显式入口冲突。没有改变命令处理、协议、控制、配置或权限，不增加全局 unsafe 编译参数。较新本机工具链此前通过的事实不能替代 Swift 6.1 的实际 CI 结果。

云端用 Swift 6.1.3 编译器最小双文件例子复现「按脚本编译 main.swift + @main」诊断；相同内容改名后直接编译并运行成功。Linux SwiftPM 6.1.3 的最小包可自动处理原文件，因此不将这个例子称为对 Apple SwiftPM 6.1.2 的完整复现。完整工程以新的 macOS CI 和本机原生复验为准。

CI 回归选择新增 `PanelMemoryTests|PanelToggleTests`，覆盖先前面板生命周期失败的确定性修复，而不是排除失败测试来得到绿色结果。
