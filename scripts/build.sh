#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

sdk="$(xcrun --sdk macosx --show-sdk-path)"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)"
app="$PWD/.build/Luqri.app"
metadata="$PWD/.build/app-intents"
deployment_target=15.0
target="$(uname -m)-apple-macos$deployment_target"
sources=("$PWD"/Luqri/*.swift)
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Icons"
mkdir -p "$metadata"

flags=(-swift-version 6 -sdk "$sdk" -target "$target")
plugin_dir="$platform/Developer/usr/lib/swift/host/plugins"
if [[ -d "$plugin_dir" ]]; then
    flags+=(-plugin-path "$plugin_dir")
fi
printf '%s\n' '["AppIntent"]' > "$metadata/protocols.json"
printf '%s\n' "${sources[@]}" > "$metadata/sources.list"
printf '%s\n' "$metadata/Luqri.swiftconstvalues" > "$metadata/constants.list"
xcrun --sdk macosx swiftc "${flags[@]}" -Osize -whole-module-optimization -module-name Luqri \
    -const-gather-protocols-list "$metadata/protocols.json" \
    -emit-const-values-path "$metadata/Luqri.swiftconstvalues" \
    "${sources[@]}" -o "$app/Contents/MacOS/Luqri"

processor="$(xcrun --find appintentsmetadataprocessor)"
toolchain="$(cd "$(dirname "$processor")/../.." && pwd)"
xcode_build="$(xcodebuild -version | awk '/^Build version / { print $3 }')"
processor_options="$("$processor" --help 2>&1 || true)"
metadata_flags=()
if [[ "$processor_options" == *--binary-file* ]]; then
    metadata_flags+=(--binary-file "$app/Contents/MacOS/Luqri")
fi
if [[ "$processor_options" == *--compile-time-extraction* ]]; then
    metadata_flags+=(--compile-time-extraction)
fi
"$processor" --output "$app/Contents/Resources" \
    --toolchain-dir "$toolchain" --module-name Luqri --sdk-root "$sdk" --xcode-version "$xcode_build" \
    --platform-family macOS --deployment-target "$deployment_target" --target-triple "$target" \
    --source-file-list "$metadata/sources.list" --swift-const-vals-list "$metadata/constants.list" \
    ${metadata_flags[@]+"${metadata_flags[@]}"}

sed -e 's/$(DEVELOPMENT_LANGUAGE)/zh-Hans/g' \
    -e 's/$(EXECUTABLE_NAME)/Luqri/g' \
    -e 's/$(PRODUCT_NAME)/Luqri/g' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.termique.luqri/g' \
    -e 's/$(MARKETING_VERSION)/0.1.0/g' \
    -e 's/$(CURRENT_PROJECT_VERSION)/1/g' \
    -e "s/\$(MACOSX_DEPLOYMENT_TARGET)/$deployment_target/g" \
    Luqri/Info.plist > "$app/Contents/Info.plist"
cp Luqri/Icons/*.svg "$app/Contents/Resources/Icons/"
cp Luqri/AppIcon.icns "$app/Contents/Resources/"
cp Luqri/Lucide-LICENSE.txt "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify "$app"
printf '%s\n' "$app"
