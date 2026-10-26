#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
app_path="$PWD/.tmp/Rimva.app"
signing_identity="${RIMVA_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" && -f .codesign-identity ]]; then
    signing_identity="$(< .codesign-identity)"
fi
if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
    print -u2 '请配置固定签名证书：设置 RIMVA_CODESIGN_IDENTITY，或将证书 SHA-1 写入 .codesign-identity。'
    exit 1
fi
if ! security find-identity -v -p codesigning | /usr/bin/grep -Fq -- "$signing_identity"; then
    print -u2 '配置的签名证书不可用。请用 just signing-identities 检查本机证书。'
    exit 1
fi
# Replacing a running development bundle would invalidate its live signature.
if /bin/ps -axo comm= | /usr/bin/grep -Fxq "$app_path/Contents/MacOS/Rimva"; then
    print -u2 '请先退出开发版 Rimva，再重新构建。'
    exit 1
fi
swift build --configuration "$configuration" --scratch-path .tmp/swift-build
binary_dir="$(swift build --configuration "$configuration" --scratch-path .tmp/swift-build --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS"
mkdir -p "$app_path/Contents/Resources"
cp "$binary_dir/Rimva" "$app_path/Contents/MacOS/Rimva"
cp -R "$binary_dir/Rimva_RimvaCore.bundle" "$app_path/Contents/Resources/"
# Xcode's shared icon compiler can retain another project's working directory.
xcrun actool "$PWD/Sources/AppIcon.icon" --compile "$app_path/Contents/Resources" \
    --app-icon AppIcon --include-all-app-icons --platform macosx --target-device mac \
    --minimum-deployment-target 14.0 --output-partial-info-plist "$PWD/.tmp/swift-build/AppIcon-partial.plist" \
    --output-format human-readable-text --errors --warnings
for language in en zh-Hans; do
    mkdir -p "$app_path/Contents/Resources/$language.lproj"
    cp "Sources/RimvaCore/Resources/$language.lproj/InfoPlist.strings" "$app_path/Contents/Resources/$language.lproj/"
done
cp Sources/Info.plist "$app_path/Contents/Info.plist"
codesign --force --sign "$signing_identity" --timestamp=none --identifier com.yfff.Rimva "$app_path"
codesign --verify --deep --strict "$app_path"
echo "$app_path"
