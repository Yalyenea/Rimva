#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source_app="$PWD/.tmp/Rimva.app"
destination="/Applications/Rimva.app"

if pgrep -x Rimva >/dev/null; then
    print -u2 '请先退出 Rimva，安装不会关闭正在编辑的图片。'
    exit 1
fi
codesign --verify --deep --strict "$source_app"
signature_info="$(codesign -dv "$source_app" 2>&1)"
if [[ "$signature_info" == *'Signature=adhoc'* ]]; then
    print -u2 '安装包仍使用临时签名，请配置固定证书并重新构建。'
    exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" != 'com.yfff.Rimva' ]]; then
    print -u2 '应用标识不匹配，安装已停止。'
    exit 1
fi
if [[ -e "$destination" && "${RIMVA_ALLOW_IDENTITY_CHANGE:-0}" != '1' ]]; then
    # Validate the update against the installed identity, including its signer.
    # Checking only a bundle identifier would let a different certificate pass.
    installed_requirement="$(codesign -d -r- "$destination" 2>/dev/null | sed -n 's/^#\{0,1\}[[:space:]]*designated => //p')"
    if [[ -z "$installed_requirement" ]] || ! codesign --verify --strict --test-requirement "=$installed_requirement" "$source_app"; then
        print -u2 '签名身份发生变化，安装已停止。仅在有意迁移证书时使用 RIMVA_ALLOW_IDENTITY_CHANGE=1 just install。'
        exit 1
    fi
fi

mkdir -p .tmp
staging="$(mktemp -d "$PWD/.tmp/install.XXXXXX")"
ditto "$source_app" "$staging/Rimva.app"
codesign --verify --deep --strict "$staging/Rimva.app"
install_complete=0
restore_previous() {
    if (( ! install_complete )) && [[ -d "$staging/previous-Rimva.app" ]]; then
        if [[ -e "$destination" ]]; then
            mv "$destination" "$staging/failed-Rimva.app"
        fi
        mv "$staging/previous-Rimva.app" "$destination"
    fi
}
trap restore_previous EXIT
if [[ -e "$destination" ]]; then
    mv "$destination" "$staging/previous-Rimva.app"
fi
mv "$staging/Rimva.app" "$destination"
codesign --verify --deep --strict "$destination"
install_complete=1
print "$destination"
