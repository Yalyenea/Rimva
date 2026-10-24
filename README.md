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

长截屏：框选滚动正文，避开固定侧栏和滚动条。分段向下滚动，停稳时自动拼接，点“完成”进入编辑器。

匹配不可靠时会提示回滚或重新框选，也可保留已拼部分。

首次截图需要在系统设置中允许 Rimva 录制屏幕。

## 本地开发

需要 macOS 14 或更新版本、Xcode 的 Swift 工具链，以及 [just](https://github.com/casey/just)。项目使用 Swift Package Manager，无第三方依赖。

### 配置固定签名

先查看本机已有的代码签名身份：

```sh
just signing-identities
```

选择长期使用的证书，将其 SHA-1 或完整名称写入项目根目录的 `.codesign-identity`（单行，本机配置，已被 Git 忽略）。也可通过环境变量指定，环境变量优先：

```sh
export RIMVA_CODESIGN_IDENTITY='<证书 SHA-1 或完整名称>'
```

构建需要钥匙串中对应的证书与私钥。缺少有效身份时会停止，不会自动创建证书或使用临时签名。不要提交个人证书信息。

### 构建与测试

```sh
just run          # 构建 Debug 应用并启动
just test         # 运行 Release 配置的核心测试
just build        # 构建 Release 应用
just build-debug  # 构建 Debug 应用
just verify       # 检查构建产物的签名
```

构建产物为 `.tmp/Rimva.app`，Bundle ID 固定为 `com.yfff.Rimva`。`just run` 使用签名后的应用包，运行前需退出已有的 Rimva 实例。直接运行 `zsh scripts/build.sh` 时，默认仍为 Debug 配置。

长截屏和性能验证使用 `just build` 或 `just install` 生成的 Release 版本。

### 安装与更新

日常使用固定安装路径 `/Applications/Rimva.app`：

```sh
just install  # 构建 Release 应用并安装，需先退出 Rimva
just launch   # 启动安装版
```

安装脚本检查签名，并拒绝覆盖正在运行的应用。默认要求新旧版本的签名身份一致。首次从旧版临时签名迁移到固定证书时，显式允许这一次身份变化：

```sh
RIMVA_ALLOW_IDENTITY_CHANGE=1 just install
just launch
```

迁移后需在系统设置中重新授予一次屏幕录制权限。此后保持同一证书、Bundle ID 和安装路径，正常更新应保留授权；macOS 主动撤销权限或要求重新确认时，按系统提示处理。

## 代码结构

- `Sources/Rimva/`：应用入口、截图流程、编辑器、设置与导出。
- `Sources/RimvaCore/`：图片合成、滚动拼接、背景模型与本地化资源。
- `Tests/RimvaCoreTests/`：合成、拼接、背景和本地化测试。
- `PLAN.md`：早期产品规划。
