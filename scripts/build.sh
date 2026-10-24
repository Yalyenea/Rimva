#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
swift build --configuration "$configuration" --scratch-path .tmp/swift-build
binary_dir="$(swift build --configuration "$configuration" --scratch-path .tmp/swift-build --show-bin-path)"
app_path="$PWD/.tmp/Rimva.app"
mkdir -p "$app_path/Contents/MacOS"
mkdir -p "$app_path/Contents/Resources"
cp "$binary_dir/Rimva" "$app_path/Contents/MacOS/Rimva"
cp -R "$binary_dir/Rimva_RimvaCore.bundle" "$app_path/Contents/Resources/"
for language in en zh-Hans; do
    mkdir -p "$app_path/Contents/Resources/$language.lproj"
    cp "Sources/RimvaCore/Resources/$language.lproj/InfoPlist.strings" "$app_path/Contents/Resources/$language.lproj/"
done
cp Sources/Info.plist "$app_path/Contents/Info.plist"
codesign --force --sign - --identifier com.yfff.Rimva "$app_path"
echo "$app_path"
