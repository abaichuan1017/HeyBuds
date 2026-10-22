#!/usr/bin/env python3
"""Verify the distributable, including resource equivalence and ZIP contents."""
import json
import plistlib
import re
import subprocess
import os
import stat
import zipfile
from source_package import ROOT

app = ROOT / 'dist/HeyBuds.app'
resources = app / 'Contents/Resources'
bundle = resources / 'HeyBuds_HeyBudsProtocol.bundle'
expected = {p.name: p for p in (ROOT / 'Sources/HeyBudsProtocol/Resources').glob('*.json')}
actual = {p.name: p for p in bundle.rglob('*.json')}
assert actual.keys() == expected.keys(), 'Unexpected or missing runtime catalogs'
for name, path in actual.items():
    assert json.loads(path.read_text()) == json.loads(expected[name].read_text()), name
for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md', 'Licenses/Realme-MIT.txt', 'Licenses/EncoDeck-GPL-3.0.txt', 'Licenses/Sparkle.txt'):
    assert (resources / name).read_bytes() == (ROOT / name).read_bytes(), name
allowed = {
    'Contents/Info.plist', 'Contents/MacOS/HeyBuds', 'Contents/_CodeSignature/CodeResources',
    'Contents/Resources/HeyBuds.icns', 'Contents/Resources/LICENSE',
    'Contents/Resources/THIRD_PARTY_NOTICES.md', 'Contents/Resources/Licenses/Realme-MIT.txt',
    'Contents/Resources/Licenses/EncoDeck-GPL-3.0.txt',
    'Contents/Resources/Licenses/Sparkle.txt',
    'Contents/Resources/HeyBuds_HeyBuds.bundle/Contents/Info.plist',
    'Contents/Resources/HeyBuds_HeyBuds.bundle/Contents/Resources/GitHub.pdf',
    'Contents/Resources/HeyBuds_HeyBudsProtocol.bundle/Contents/Info.plist',
} | {p.relative_to(app).as_posix() for p in actual.values()}
def entries(directory):
    return {p.relative_to(directory).as_posix(): p for p in directory.rglob('*') if p.is_symlink() or p.is_file()}

def bytes_or_link(path):
    return os.readlink(path).encode() if path.is_symlink() else path.read_bytes()

# SwiftPM verifies the pinned binary artifact checksum. Embedded Sparkle must
# match that artifact exactly, including its relative, in-bundle symlinks.
upstream = ROOT / '.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
framework = app / 'Contents/Frameworks/Sparkle.framework'
original = entries(upstream)
embedded = entries(framework)
assert original.keys() == embedded.keys(), 'Sparkle bundle differs from the pinned artifact'
for name, path in embedded.items():
    assert path.is_symlink() == original[name].is_symlink() and bytes_or_link(path) == bytes_or_link(original[name]), name
    if path.is_symlink():
        assert not os.path.isabs(os.readlink(path))
        assert path.resolve().is_relative_to(framework.resolve()), 'Escaping framework symlink'
allowed |= {'Contents/Frameworks/Sparkle.framework/' + name for name in embedded}
files = entries(app)
assert set(files) == allowed, f'Unexpected app contents: {set(files) ^ allowed}'
assert (resources / 'HeyBuds_HeyBuds.bundle/Contents/Resources/GitHub.pdf').read_bytes() == (ROOT / 'Sources/HeyBuds/Resources/GitHub.pdf').read_bytes()
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'local.heybuds.app'
version = re.search(r'static let version="([^"]+)"', (ROOT / 'Sources/HeyBuds/AppIdentity.swift').read_text()).group(1)
assert info['CFBundleShortVersionString'] == version
assert info['LSMinimumSystemVersion'] == '26.0'
assert info['LSUIElement'] is True
assert info['SUFeedURL'] == 'https://raw.githubusercontent.com/abaichuan1017/HeyBuds/main/docs/appcast.xml'
assert info['SURequireSignedFeed'] is True and info['SUVerifyUpdateBeforeExtraction'] is True
assert info['SUEnableAutomaticChecks'] is False and info['SUAllowsAutomaticUpdates'] is False
assert info['SUSendProfileInfo'] is False
import base64
assert len(base64.b64decode(info['SUPublicEDKey'], validate=True)) == 32
assert subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/HeyBuds')], text=True).strip() == 'arm64'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
archive = ROOT / 'dist/HeyBuds-arm64.zip'
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    assert len(z.namelist()) == len(set(z.namelist())), 'Duplicate ZIP entries'
    entries = {n for n in z.namelist() if not n.endswith('/')}
    assert entries == {'HeyBuds.app/' + name for name in files}, 'ZIP contains extra or missing files'
    for name, path in files.items():
        assert z.read('HeyBuds.app/' + name) == bytes_or_link(path), name
        assert stat.S_ISLNK(z.getinfo('HeyBuds.app/' + name).external_attr >> 16) == path.is_symlink(), name
print(f'App audit passed: {len(files)} files, {sum(p.stat().st_size for p in files.values())} app bytes, {archive.stat().st_size} ZIP bytes.')
