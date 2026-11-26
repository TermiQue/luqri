#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 1 || ( $# -eq 1 && $1 != --universal ) ]]; then
    printf '用法：%s [--universal]\n' "$0" >&2
    exit 2
fi

read_setting() {
    local value
    value="$(awk -v key="$1" '$1 == key && $2 == "=" {print $3}' Build.xcconfig)"
    if [[ ! $value =~ ^[[:alnum:].-]+$ ]]; then
        printf 'Build.xcconfig 缺少有效的 %s。\n' "$1" >&2
        return 1
    fi
    printf '%s\n' "$value"
}

deployment_target="$(read_setting MACOSX_DEPLOYMENT_TARGET)"
bundle_id="$(read_setting PRODUCT_BUNDLE_IDENTIFIER)"
version="$(read_setting MARKETING_VERSION)"
build_number="$(read_setting CURRENT_PROJECT_VERSION)"

sdk="$(xcrun --sdk macosx --show-sdk-path)"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
app="${LUQRI_APP_PATH:-$PWD/.build/Luqri.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Icons"

flags=(-swift-version 6 -sdk "$sdk" -Osize -whole-module-optimization)
plugin_dir="$platform/Developer/usr/lib/swift/host/plugins"
if [[ -d "$plugin_dir" ]]; then
    flags+=(-plugin-path "$plugin_dir")
fi
if [[ ${1:-} == --universal ]]; then
    slices="$(mktemp -d)"
    trap 'rm -r "$slices"' EXIT
    for arch in arm64 x86_64; do
        xcrun --sdk macosx swiftc "${flags[@]}" -target "$arch-apple-macos$deployment_target" \
            Luqri/*.swift -o "$slices/$arch"
    done
    xcrun lipo -create "$slices/arm64" "$slices/x86_64" -output "$app/Contents/MacOS/Luqri"
else
    xcrun --sdk macosx swiftc "${flags[@]}" -target "$(uname -m)-apple-macos$deployment_target" \
        Luqri/*.swift -o "$app/Contents/MacOS/Luqri"
fi

# Drop local and debug symbols before signing the distributed executable.
xcrun strip -S -x "$app/Contents/MacOS/Luqri"

sed -e 's/$(DEVELOPMENT_LANGUAGE)/zh-Hans/g' \
    -e 's/$(EXECUTABLE_NAME)/Luqri/g' \
    -e 's/$(PRODUCT_NAME)/Luqri/g' \
    -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$bundle_id/g" \
    -e "s/\$(MARKETING_VERSION)/$version/g" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$build_number/g" \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$deployment_target/g" \
    Luqri/Info.plist > "$app/Contents/Info.plist"
cp Luqri/Icons/*.svg "$app/Contents/Resources/Icons/"
cp Luqri/LuqriAppIcon.icns "$app/Contents/Resources/"
cp Luqri/Lucide-LICENSE.txt "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify --strict --all-architectures "$app"
printf '%s\n' "$app"
