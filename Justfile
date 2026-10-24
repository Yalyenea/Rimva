# Rimva 开发与安装入口；运行 `just` 查看命令。

default:
    @just --list

# 构建 Release 应用。
build:
    zsh scripts/build.sh release

# 构建 Debug 应用。
build-debug:
    zsh scripts/build.sh debug

# 运行核心测试。
test:
    swift test --configuration release --scratch-path .tmp/swift-build

# 构建并启动开发应用；先退出已运行的 Rimva。
run:
    #!/bin/zsh
    set -euo pipefail
    if pgrep -x Rimva >/dev/null; then
        print -u2 "请先退出正在运行的 Rimva，再运行 just run。"
        exit 1
    fi
    just build-debug
    open .tmp/Rimva.app

# 构建后安装到 /Applications/Rimva.app。
install: build
    zsh scripts/install.sh

# 启动已安装的应用。
launch:
    open /Applications/Rimva.app

# 列出本机可用的代码签名身份。
signing-identities:
    security find-identity -v -p codesigning

# 验证构建产物的签名，并显示身份信息。
verify:
    codesign --verify --deep --strict --verbose=2 .tmp/Rimva.app
    codesign --display --verbose=2 .tmp/Rimva.app
