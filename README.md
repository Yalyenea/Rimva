# Rimva

轻量的原生 macOS 截图工具，支持截图、添加背景、标注、复制和保存。

## 功能

- 区域、窗口、全屏和滚动长截屏。
- 箭头、矩形、文字、序号、实色遮挡、裁剪及撤销重做。
- 背景预设、自定义图片、图片文件夹与 macOS 壁纸。
- 留白、圆角、阴影，以及日间和夜间背景。
- 中英双语、跟随系统的语言与外观、应用主题。
- 可配置的全局快捷键、截图后自动复制、PNG 导出。

默认按 `⌃⌥S` 打开截图入口，再按 `1` 选择普通截图或 `2` 选择长截屏。

长截屏：框选区域后向下滚动，停稳时自动拼接，点“完成”进入编辑器。滚动时保留部分重叠画面。

首次截图需要在系统设置中允许 Rimva 录制屏幕。

## 本地开发

需要 macOS 14 或更新版本，以及 Xcode 的 Swift 工具链。项目使用 Swift Package Manager，无第三方依赖。

```sh
zsh scripts/build.sh
open .tmp/Rimva.app
```

构建 Release 版本：

```sh
zsh scripts/build.sh release
```

运行测试：

```sh
swift test --scratch-path .tmp/swift-build
```

构建脚本将应用写入 `.tmp/Rimva.app`，并进行本地临时签名。

## 代码结构

- `Sources/Rimva/`：应用入口、截图流程、编辑器、设置与导出。
- `Sources/RimvaCore/`：图片合成、滚动拼接、背景模型与本地化资源。
- `Tests/RimvaCoreTests/`：合成、拼接、背景和本地化测试。
- `PLAN.md`：早期产品规划。
