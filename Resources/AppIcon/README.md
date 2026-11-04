# MijiaLAN 应用图标

原创图形使用蓝绿渐变的圆角方形、暖白房屋轮廓和三个相连的局域网节点，表示本地智能家居桥接。
不使用 Apple、米家、Aqara 或 Matter 的商标图形，没有文字，透明外边距已包含在素材内。

## 可维护素材

- `AppIcon.source.png`：1254 × 1254 RGBA 高分辨率设计母版，由图像生成工具创作，作为图标设计源文件保留。
- `../AppIcon.iconset/`：macOS 标准的十个 PNG 文件，包含 16、32、128、256、512 点的 1× / 2× 版本。
- `../AppIcon.icns`：打包使用的最终资源，包含上述十个 PNG 表示，最大 1024 × 1024 像素。
- `manifest.json`：母版、派生 PNG 与 ICNS 的 SHA-256，用于发现陈旧或损坏资源。
- `../../scripts/app_icon.py`：确定性缩放和 ICNS 封装工具；`--check` 不修改文件，且仅依赖 Python 标准库。

设计母版为位图，不是可编辑矢量文件。修改设计时更新母版，再一次性重建全部派生资源；不要单独修改某个小尺寸后遗忘更新 ICNS。

母版创作方向：一个居中的原创 macOS 圆角方形图标，深蓝至青绿渐变、轻微材质层次和边缘高光；
暖白粗线条房屋轮廓，内部为三个圆形局域网节点组成的连接结构；对称、简洁、无文字、无品牌标记，外侧透明。

## 云端或维护者重新生成

在仓库根目录执行：

```sh
python3 -m venv /tmp/mijialan-icon-venv
/tmp/mijialan-icon-venv/bin/pip install -r Resources/AppIcon/requirements.txt
/tmp/mijialan-icon-venv/bin/python scripts/app_icon.py
python3 scripts/app_icon.py --check
```

Pillow 只用于重新生成素材。正常 Debug、Release 和发行构建使用已提交的 ICNS，不安装 Pillow。
生成器使用 PNG 格式的 ICNS 表示，适用于项目所要求的现代 macOS，不提供旧版 macOS 的 RLE 图标表示。

## 打包接入

`scripts/build_app.sh` 的 Debug 和 Release 路径均在构建前验证资源，将 `AppIcon.icns` 复制到
`Contents/Resources`，设置 `CFBundleIconFile = AppIcon.icns`，并在签名前验证最终包。
正式发行脚本复用该构建流程；`--package-existing` 也验证暂存 App 的图标，避免继续打包没有图标的旧产物。
`LSUIElement` 和菜单栏图标逻辑不作修改。

```sh
python3 scripts/app_icon.py --check --app build/MijiaLAN.app
```

## 验证边界与本地复测

云端已验证十个尺寸、PNG 校验和、ICNS 结构和散列，以及使用 Pillow 独立解码每个 ICNS 表示。
还通过临时 App 验证了生成的 Info.plist、图标复制路径，并确认缺失声明、错误声明、缺失或损坏图标会被拒绝。
构建和发行脚本的 shell 语法检查通过。云端没有运行 macOS `iconutil`、Finder、签名或公证。

本地重新拉取后，先运行现有 `scripts/validate_macos.sh`，它现在也检查包内图标。
再用 Apple 工具独立解码（输出写入临时目录，不修改源码）：

```sh
iconutil -c iconset Resources/AppIcon.icns -o /tmp/MijiaLAN-AppIcon-check.iconset
```

使用一个新的临时输出目录，避免覆盖之前的结果。检查 Finder 中新构建 App 的列表、图标和「显示简介」视图，
覆盖小尺寸和大尺寸、浅色及深色背景。如果 Finder 缓存了旧图标，先关闭相关窗口、将新构建 App 复制到新的临时目录再查看；
不要把清除系统缓存当作默认测试步骤。
该 App 仍是菜单栏应用，不应为了测试图标改为常驻 Dock 或修改 `LSUIElement`。
本次修改不启动桥接、不需要登录或真实设备，也不发布 Release。
