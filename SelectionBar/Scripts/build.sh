#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build -c release -j 4
binary_dir="$(swift build -c release --show-bin-path)"
app_path="$project_dir/dist/SelectionBar.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/SelectionBar" "$app_path/Contents/MacOS/SelectionBar"
cp "$binary_dir/SelectionBarRuntime" "$app_path/Contents/MacOS/SelectionBarRuntime"
resource_path="$binary_dir/SelectionBar_SelectionBarCore.bundle"
if [ -d "$resource_path" ]; then /usr/bin/ditto "$resource_path" "$app_path/Contents/Resources/SelectionBar_SelectionBarCore.bundle"; fi
cp Scripts/Info.plist "$app_path/Contents/Info.plist"
python3 ../scripts/localization/package-resources.py "$binary_dir" "$app_path" SelectionBar_SelectionBarCore
if [ ! -f "$app_path/Contents/Resources/SelectionBar.icns" ]; then
  xcrun swift Scripts/icon.swift "$project_dir/.local/Icon.iconset"
  /usr/bin/iconutil -c icns "$project_dir/.local/Icon.iconset" -o "$app_path/Contents/Resources/SelectionBar.icns"
fi
identity_file="$project_dir/.local/signing-identity"
if [ ! -f "$identity_file" ] && [ -f "$project_dir/../BarPilot/.local/barpilot-signing-identity" ]; then
  mkdir -p "$project_dir/.local"
  cp "$project_dir/../BarPilot/.local/barpilot-signing-identity" "$identity_file"
  chmod 600 "$identity_file"
fi
sign_identity="-"
if [ -f "$identity_file" ]; then sign_identity="$(cat "$identity_file")"; fi
/usr/bin/codesign --force --options runtime --entitlements Scripts/entitlements.plist --sign "$sign_identity" "$app_path/Contents/MacOS/SelectionBarRuntime"
/usr/bin/codesign --force --options runtime --entitlements Scripts/entitlements.plist --sign "$sign_identity" "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path"
