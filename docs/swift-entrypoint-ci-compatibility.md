# Swift CI 工具链与入口兼容

GitHub Actions 已取得 macOS 15 arm64 runner 并开始实际编译；本轮故障不是排队取消或设备通信问题。CI 的 Linux Matter 作业通过，原生 Swift 编译先后暴露以下问题。

## CLI 入口

运行 `43566926415` 使用默认 Xcode 16.4 / Apple Swift 6.1.2，CLI 编译失败在旧 `Sources/mijia-lan/main.swift:17`：`'main' attribute cannot be used in a module that contains top-level code`。

CLI 使用 `@main struct MijiaLANCommand`，将文件重命名为 `MijiaLANCommand.swift`，避免 `main.swift` 隐式脚本入口与显式入口冲突。没有改变命令处理、协议、控制、配置或权限，不增加全局 unsafe 编译参数。后续原生 CLI 编译已通过。

云端 Swift 6.1.3 编译器最小双文件例子复现「按脚本编译 main.swift + @main」诊断；相同内容改名后直接编译并运行成功。Linux SwiftPM 6.1.3 的最小包可自动处理原文件，因此不将这个例子称为对 Apple SwiftPM 6.1.2 的完整复现。

## SwiftUI 类型推断与 Binding 回调

原生 App 编译暴露既有 `LampColorTemperatureControl.body` 的 Swift 6.1 类型推断超时。将标题/输入、滑块、Binding、辅助功能字符串和编辑动作拆为小表达式；State、量化公式、松手提交、键盘步进、草稿清理与可用性逻辑保持一致。

进一步编译时，Apple Swift 6.1.2 在生成色温 Double 的 actor 隔离回调适配器 IR 时崩溃（SmallVector capacity 4294967297）。改用显式转发闭包后，故障推进到登录项开关 `Binding(set: setRegistered)` 的 Bool 适配器；Xcode 26.2 / Swift 6.2.3 也复现了后者，见运行 `43571117289`。两处都使用显式闭包调用原方法，避免直接方法引用的编译器适配路径。不更改动作时机或登录项授权流程。

CI 明确使用该镜像预装的 Xcode 26.2，并打印 Xcode/Swift 版本，避免随默认工具链变化。macOS 15 部署目标不变；升级工具链本身并未消除上述 Bool 崩溃，仍需源代码适配。不能宣称所有旧 Swift 版本已通过原生验证。

CI 回归选择加入 `PanelMemoryTests|PanelToggleTests`，覆盖先前面板生命周期失败的确定性修复；原有构建与回归保持执行。最终完整结果以新提交的原生 CI、本机编译和验证脚本为准，Linux 语法解析不代替 SwiftUI 类型检查。

## ARM64 runner 容量不足

最近三个提交 `8a7f486`、`07c842c`、`54e4743` 的 PR Swift 作业均没有开始任何步骤，约 15 分钟后取消，整个 workflow 显示 failure。GitHub 的 Annotations 明确包含 `The job was not acquired by Runner of type hosted even after multiple attempts`、`Internal server error` 和 `Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times.` 这是分配机器失败，不能视为这些提交已经编译失败或通过。对应 [54e4743 作业](https://github.com/MeteorsHub/MijiaLAN/actions/runs/44345396007/job/134946284503)、[07c842c 作业](https://github.com/MeteorsHub/MijiaLAN/actions/runs/44335404704/job/134910606132)、[8a7f486 作业](https://github.com/MeteorsHub/MijiaLAN/actions/runs/43901679857/job/133419642884)；同次 Linux Matter 作业均通过。

Swift 作业改用 GitHub 标准 `macos-15-intel` 池，继续固定 Xcode 26.2，打印实际机器架构，原 CLI/App 编译、核心库与 App/协议回归保持执行。[官方 runner 列表](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) 区分 Intel 标签与默认 ARM64 的 `macos-15`；[Intel 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md) 列有 Xcode 26.2。切换只改变 CI 执行架构，不改变 App 部署目标、设备协议或本地家庭 Mac 的 ARM64 验证要求；Intel 通过不等同于 ARM64 原生验证通过。

每次提交同时触发 push 与 pull_request 两次运行；这是当前配置的正常行为，故同一基础设施故障可能出现两条失败通知。不能把它当作两个独立代码错误，也不为减少红色提示而跳过检查。
