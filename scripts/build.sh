#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

sdk="$(xcrun --sdk macosx --show-sdk-path)"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
app="$PWD/.build/Luqri.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Icons"

flags=(-swift-version 6 -sdk "$sdk" -target "$(uname -m)-apple-macos15.0")
plugin_dir="$platform/Developer/usr/lib/swift/host/plugins"
if [[ -d "$plugin_dir" ]]; then
    flags+=(-plugin-path "$plugin_dir")
fi
xcrun --sdk macosx swiftc "${flags[@]}" -Osize -whole-module-optimization \
    Luqri/*.swift -o "$app/Contents/MacOS/Luqri"

sed -e 's/$(DEVELOPMENT_LANGUAGE)/zh-Hans/g' \
    -e 's/$(EXECUTABLE_NAME)/Luqri/g' \
    -e 's/$(PRODUCT_NAME)/Luqri/g' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.termique.luqri/g' \
    -e 's/$(MARKETING_VERSION)/0.1.0/g' \
    -e 's/$(CURRENT_PROJECT_VERSION)/1/g' \
    -e 's/$(MACOSX_DEPLOYMENT_TARGET)/15.0/g' \
    Luqri/Info.plist > "$app/Contents/Info.plist"
cp Luqri/Icons/*.svg "$app/Contents/Resources/Icons/"
cp Luqri/Lucide-LICENSE.txt "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify "$app"
printf '%s\n' "$app"
