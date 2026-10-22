#!/usr/bin/env python3
"""Verify the distributable, including resource equivalence and ZIP contents."""
import json
import plistlib
import subprocess
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
for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md', 'Licenses/Realme-MIT.txt'):
    assert (resources / name).read_bytes() == (ROOT / name).read_bytes(), name
allowed = {
    'Contents/Info.plist', 'Contents/MacOS/HeyBuds', 'Contents/_CodeSignature/CodeResources',
    'Contents/Resources/HeyBuds.icns', 'Contents/Resources/LICENSE',
    'Contents/Resources/THIRD_PARTY_NOTICES.md', 'Contents/Resources/Licenses/Realme-MIT.txt',
    'Contents/Resources/HeyBuds_HeyBudsProtocol.bundle/Contents/Info.plist',
} | {p.relative_to(app).as_posix() for p in actual.values()}
files = {p.relative_to(app).as_posix(): p for p in app.rglob('*') if p.is_file()}
assert set(files) == allowed, f'Unexpected app contents: {set(files) ^ allowed}'
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'local.heybuds.app'
assert info['LSUIElement'] is True
assert subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/HeyBuds')], text=True).strip() == 'arm64'
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
archive = ROOT / 'dist/HeyBuds-arm64.zip'
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    assert len(z.namelist()) == len(set(z.namelist())), 'Duplicate ZIP entries'
    entries = {n for n in z.namelist() if not n.endswith('/')}
    assert entries == {'HeyBuds.app/' + name for name in files}, 'ZIP contains extra or missing files'
    for name, path in files.items():
        assert z.read('HeyBuds.app/' + name) == path.read_bytes(), name
print(f'App audit passed: {len(files)} files, {sum(p.stat().st_size for p in files.values())} app bytes, {archive.stat().st_size} ZIP bytes.')
