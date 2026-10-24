# Rimva

原生 macOS 截图工具，使用 Swift、AppKit 与 Swift Package Manager。界面保持简洁、紧凑、扁平。

## 开发入口

- 修改前阅读 [README.md](README.md)，通过 [Justfile](Justfile) 构建、测试和运行。
- `just run` 构建并启动 `.tmp/Rimva.app`；`just build` 构建 Release 版本；`just test` 运行核心测试。
- 长截屏和性能验证使用 Release 应用包。
- `.tmp/Rimva.app` 用于开发，`/Applications/Rimva.app` 用于日常使用。安装使用 `just install`，启动安装版使用 `just launch`。
- 运行前检查已有实例，先退出 Rimva。避免重复启动，也不要使用 `open -n`。

## 签名与权限

- Bundle ID 固定为 `com.yfff.Rimva`。构建与安装始终使用同一代码签名证书。
- 签名身份由 `RIMVA_CODESIGN_IDENTITY` 或本机 `.codesign-identity` 指定。缺少身份时直接失败；禁止临时签名、自动创建证书或降级。
- `.codesign-identity` 属于本机配置，不提交个人证书信息。
- 通过构建的应用包验证屏幕录制权限，避免 `swift run` 产生另一运行身份。
- 安装前退出应用。签名身份变化必须显式设置 `RIMVA_ALLOW_IDENTITY_CHANGE=1`。
- 权限由系统设置管理；不要清除或修改系统权限数据库，也不要自动修改钥匙串信任。

## 工程约定

- 新功能与修复使用新 Git 分支，未经用户要求不提交。
- 临时文件与构建产物放在 `.tmp/`，待删除内容放在 `.tmp/trash/`。
- 实现保持直接，避免静默兜底和不必要的兼容层。按风险运行最小且相关的检查。
- 文档按任务明确要求的范围更新；提交前同步与该次变更有关的说明。保持现有文件结构精简。
