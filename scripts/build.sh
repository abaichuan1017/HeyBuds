#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-release}
if [[ "$config" != release && "$config" != debug ]]; then echo 'Usage: bash scripts/build.sh [release|debug]' >&2; exit 2; fi
swift build -c "$config" --arch arm64 --product HeyBuds
bin_dir=$(swift build -c "$config" --arch arm64 --show-bin-path)
mkdir -p dist
stage=$(mktemp -d "$PWD/dist/.HeyBuds-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/HeyBuds.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/HeyBuds" "$app/Contents/MacOS/HeyBuds"
if [[ "$config" == release ]]; then xcrun strip -S -x "$app/Contents/MacOS/HeyBuds"; fi
cp -R "$bin_dir/HeyBuds_HeyBudsProtocol.bundle" "$app/Contents/Resources/"
# Keep the source catalogs readable; ship equivalent compact JSON in the app.
python3 - "$app/Contents/Resources/HeyBuds_HeyBudsProtocol.bundle" <<'PY'
import json
import pathlib
import sys
sources = {p.name: p for p in pathlib.Path('Sources/HeyBudsProtocol/Resources').glob('*.json')}
seen = set()
for path in pathlib.Path(sys.argv[1]).rglob('*.json'):
    if path.name not in sources:
        path.unlink()  # Also discard stale resources left by an incremental build.
        continue
    value = json.loads(path.read_text())
    assert value == json.loads(sources[path.name].read_text()), path.name
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':')) + '\n')
    seen.add(path.name)
assert seen == sources.keys(), 'Missing runtime catalog'
PY
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
cp -R Licenses "$app/Contents/Resources/"
xcrun swift scripts/make-icon.swift "$stage/HeyBuds.iconset"
iconutil -c icns "$stage/HeyBuds.iconset" -o "$app/Contents/Resources/HeyBuds.icns"
# Recompress PNG streams losslessly; keep every icon size, pixel and metadata chunk.
python3 - "$app/Contents/Resources/HeyBuds.icns" <<'PY'
from pathlib import Path
import struct
import sys
import zlib

def compact_png(data):
    if not data.startswith(b'\x89PNG\r\n\x1a\n'):
        return data
    chunks = []
    offset = 8
    while offset < len(data):
        size = struct.unpack_from('>I', data, offset)[0]
        kind = data[offset + 4:offset + 8]
        chunks.append((kind, data[offset + 8:offset + 8 + size]))
        offset += size + 12
    original = b''.join(value for kind, value in chunks if kind == b'IDAT')
    packed = zlib.compress(zlib.decompress(original), 9)
    if len(packed) >= len(original):
        return data
    result = data[:8]
    written = False
    for kind, value in chunks:
        if kind == b'IDAT':
            if written:
                continue
            value = packed
            written = True
        result += struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value))
    assert zlib.decompress(packed) == zlib.decompress(original)
    return result

path = Path(sys.argv[1])
data = path.read_bytes()
assert data[:4] == b'icns' and struct.unpack_from('>I', data, 4)[0] == len(data)
offset = 8
result = b''
while offset < len(data):
    kind, size = struct.unpack_from('>4sI', data, offset)
    value = compact_png(data[offset + 8:offset + size])
    result += struct.pack('>4sI', kind, len(value) + 8) + value
    offset += size
path.write_bytes(b'icns' + struct.pack('>I', len(result) + 8) + result)
PY
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.heybuds.app</string>
<key>CFBundleExecutable</key><string>HeyBuds</string>
<key>CFBundleName</key><string>HeyBuds</string>
<key>CFBundleDisplayName</key><string>HeyBuds</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.4</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>en</string></array>
<key>CFBundleIconFile</key><string>HeyBuds.icns</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
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
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --keepParent dist/HeyBuds.app "$stage/HeyBuds-arm64.zip"
mv "$stage/HeyBuds-arm64.zip" dist/HeyBuds-arm64.zip
echo "Built: $PWD/dist/HeyBuds.app"
