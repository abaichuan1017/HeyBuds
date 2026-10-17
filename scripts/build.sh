#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-release}
if [[ "$config" != release && "$config" != debug ]]; then echo 'Usage: bash scripts/build.sh [release|debug]' >&2; exit 2; fi
swift build -c "$config" --arch arm64
bin_dir=$(swift build -c "$config" --arch arm64 --show-bin-path)
mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.HeyBuds-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/HeyBuds.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/HeyBuds" "$app/Contents/MacOS/HeyBuds"
cp -R "$bin_dir/HeyBuds_HeyBudsProtocol.bundle" "$app/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp -R Licenses "$app/Contents/Resources/"
xcrun swift scripts/make-icon.swift "$stage/HeyBuds.iconset"
iconutil -c icns "$stage/HeyBuds.iconset" -o "$app/Contents/Resources/HeyBuds.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.heybuds.app</string>
<key>CFBundleExecutable</key><string>HeyBuds</string>
<key>CFBundleName</key><string>HeyBuds</string>
<key>CFBundleDisplayName</key><string>HeyBuds</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleIconFile</key><string>HeyBuds.icns</string>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>HeyBuds 通过蓝牙读取耳机电量，并控制降噪和音效。

HeyBuds uses Bluetooth to read earbud battery levels and control noise cancellation and sound.</string>
<key>NSHumanReadableCopyright</key><string>HeyBuds contributors. GPL-3.0-or-later. Includes attributed third-party code.</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign "${HEYBUDS_SIGN_IDENTITY:--}" --identifier local.heybuds.app "$app"
codesign --verify --strict "$app"
test "$(lipo -archs "$app/Contents/MacOS/HeyBuds")" = arm64
if [[ -e dist/HeyBuds.app ]]; then
  mkdir -p dist/backups
  mv dist/HeyBuds.app "dist/backups/HeyBuds-$(date +%Y%m%d-%H%M%S)-$$.app"
fi
mv "$app" dist/HeyBuds.app
ditto -c -k --sequesterRsrc --keepParent dist/HeyBuds.app dist/HeyBuds-arm64.zip
echo "Built: $PWD/dist/HeyBuds.app"
