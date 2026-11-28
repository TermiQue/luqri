#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

local_build=0
architecture=universal
write_checksum=1
for option in "$@"; do
    case "$option" in
        --local) local_build=1 ;;
        --arm64) architecture=arm64 ;;
        --no-sha256) write_checksum=0 ;;
        *)
            printf '用法：%s [--local] [--arm64] [--no-sha256]\n' "$0" >&2
            exit 2
            ;;
    esac
done

identity=-
suffix=-adhoc
if [[ $local_build == 0 ]]; then
    : "${LUQRI_SIGN_IDENTITY:?请指定 Developer ID Application 签名身份，或使用 --local 生成本地测试包。}"
    : "${LUQRI_NOTARY_PROFILE:?请指定 notarytool 钥匙串凭据名称。}"
    if [[ $LUQRI_SIGN_IDENTITY == - ]] ||
        ! security find-identity -v -p codesigning | grep 'Developer ID Application:' >/dev/null; then
        printf '正式打包需要钥匙串中的 Developer ID Application 签名身份。\n' >&2
        exit 1
    fi
    identity="$LUQRI_SIGN_IDENTITY"
    suffix=
fi

mkdir -p .build
scratch="$(mktemp -d "$PWD/.build/luqri-package.XXXXXX")"
mount="$scratch/mount"
mounted=0
cleanup() {
    if [[ $mounted == 1 ]]; then hdiutil detach "$mount" >/dev/null || return; fi
    rm -r "$scratch"
}
trap cleanup EXIT

app="$scratch/stage/Luqri.app"
LUQRI_APP_PATH="$app" ./scripts/build.sh "--$architecture"
if [[ $identity != - ]]; then
    codesign --force --sign "$identity" --options runtime --timestamp "$app"
    if ! codesign --display --verbose=4 "$app" 2>&1 | grep '^Authority=Developer ID Application:' >/dev/null; then
        printf '请使用 Developer ID Application 证书签名。\n' >&2
        exit 1
    fi
fi
codesign --verify --strict --all-architectures "$app"

version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
bundle_id="$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")"
if [[ $architecture == arm64 ]]; then
    filename="Luqri-${version}-macOS-arm64.dmg"
else
    filename="Luqri-${version}-universal${suffix}.dmg"
fi
dmg="$scratch/$filename"
ln -s /Applications "$scratch/stage/Applications"
hdiutil create -srcfolder "$scratch/stage" -volname "Luqri $version" -fs HFS+ -format UDZO "$dmg"

if [[ $identity == - ]]; then
    codesign --sign - --identifier "$bundle_id.dmg" "$dmg"
else
    codesign --sign "$identity" --timestamp --identifier "$bundle_id.dmg" "$dmg"
    if ! xcrun notarytool submit "$dmg" --keychain-profile "$LUQRI_NOTARY_PROFILE" --wait --output-format json > "$scratch/notary.json" ||
        [[ "$(plutil -extract status raw "$scratch/notary.json")" != Accepted ]]; then
        cat "$scratch/notary.json" >&2
        exit 1
    fi
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature "$dmg"
fi

codesign --verify --strict "$dmg"
hdiutil verify -quiet "$dmg"
mkdir "$mount"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$dmg" >/dev/null
mounted=1
mounted_app="$mount/Luqri.app"
codesign --verify --strict --all-architectures "$mounted_app"
architectures="$(xcrun lipo -archs "$mounted_app/Contents/MacOS/Luqri")"
if [[ $architecture == arm64 ]]; then
    [[ $architectures == arm64 ]]
else
    [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]
fi
[[ "$(readlink "$mount/Applications")" == /Applications ]]
hdiutil detach "$mount" >/dev/null
mounted=0

if [[ $write_checksum == 1 ]]; then
    (cd "$scratch" && shasum -a 256 "$filename" > "$filename.sha256")
fi
mv "$dmg" "$PWD/.build/$filename"
printf '%s\n' "$PWD/.build/$filename"
if [[ $write_checksum == 1 ]]; then
    mv "$scratch/$filename.sha256" "$PWD/.build/$filename.sha256"
    printf '%s\n' "$PWD/.build/$filename.sha256"
fi
