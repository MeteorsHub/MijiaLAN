# Swift 6.1 CI 入口文件兼容

GitHub Actions 运行 `43566926415` 已取得 macOS 15 arm64 runner，实际使用 Apple Swift 6.1.2。CLI 编译失败在 `Sources/mijia-lan/main.swift:17`：`'main' attribute cannot be used in a module that contains top-level code`。Matter 作业成功，尚未执行 App 编译或 Swift 测试；此次不是排队取消或设备问题。

CLI 使用 `@main struct MijiaLANCommand`，将文件重命名为 `MijiaLANCommand.swift`，避免 `main.swift` 隐式脚本入口与显式入口冲突。没有改变命令处理、协议、控制、配置或权限，不增加全局 unsafe 编译参数。较新本机工具链此前通过的事实不能替代 Swift 6.1 的实际 CI 结果。

云端用 Swift 6.1.3 编译器最小双文件例子复现「按脚本编译 main.swift + @main」诊断；相同内容改名后直接编译并运行成功。Linux SwiftPM 6.1.3 的最小包可自动处理原文件，因此不将这个例子称为对 Apple SwiftPM 6.1.2 的完整复现。完整工程以新的 macOS CI 和本机原生复验为准。

CI 回归选择新增 `PanelMemoryTests|PanelToggleTests`，覆盖先前面板生命周期失败的确定性修复，而不是排除失败测试来得到绿色结果。

后续运行 `43570171485` 的 CLI 已编译通过；App 首次继续编译时暴露 `LampColorTemperatureControl.body` 的 Swift 6.1 类型推断超时。该控件从 main 原样继承，本轮 Matter 修改未触及它。将其标题/输入、滑块，以及复杂 Binding、辅助功能字符串和编辑动作拆为具名小表达式；State、量化公式、松手提交、键盘步进、草稿清理与外层可用性逻辑保持一致。需要新的原生 CI 确认，不将 Linux 语法解析视为 SwiftUI 类型检查。

拆分后运行 `43570448078` 通过类型检查，但 Apple Swift 6.1.2 在生成色温控件的 actor 隔离 Double 回调适配器 IR 时崩溃（SmallVector capacity 4294967297）。将 Binding/编辑回调的直接方法引用改成显式转发闭包，避免这个编译器适配路径；回调参数与处理逻辑不变。新结果仍由后续 CI 确认。

运行 `43570783578` 进一步表明：显式闭包绕过了色温 Double 崩溃，旧编译器随后在 `ControlCenterSettings.swift` 的同类 Bool actor-binding thunk 生成时再次崩溃。这里不是设备运行错误，也不是继续拆设备/协议代码的依据。核对该 runner 镜像的官方软件清单确认预装 Xcode 26.2，因此 CI 明确设置 `DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer`，同时打印 Xcode/Swift 版本。全部构建与回归步骤继续执行，macOS 15 部署目标和正常产品逻辑不变。旧编译器崩溃日志保留作为兼容性边界，不宣称所有 Swift 6.1.2 App 编译均已修复。
