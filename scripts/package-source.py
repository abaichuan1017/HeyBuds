#!/usr/bin/env python3
"""Build a deterministic public source archive, without local Git history."""
import hashlib
import importlib.util
import json
import stat
import zipfile
from source_package import ROOT

spec = importlib.util.spec_from_file_location('heybuds_audit', ROOT / 'scripts/audit-source.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
files, version = audit.audit()
output = ROOT / 'releases'
output.mkdir(exist_ok=True)
archive = output / f'HeyBuds-v{version}-source.zip'
manifest = []
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        data = path.read_bytes()
        info = zipfile.ZipInfo('HeyBuds/' + relative, date_time=(2026, 10, 17, 0, 0, 0))
        info.create_system = 3
        mode = 0o755 if path.suffix == '.sh' else 0o644
        info.external_attr = (stat.S_IFREG | mode) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, data)
        manifest.append({'path': relative, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    assert len(z.namelist()) == len(files)
manifest_file = output / 'source-manifest.json'
manifest_file.write_text(json.dumps({'app': 'HeyBuds', 'version': version, 'files': manifest}, indent=2) + '\n')
artifacts = [archive, manifest_file]
app_image = ROOT / 'dist/HeyBuds-arm64.dmg'
if app_image.is_file():
    artifacts.append(app_image)
checksums = '\n'.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name for p in artifacts) + '\n'
(output / 'SHA256SUMS').write_text(checksums)
print(f'Created {archive.relative_to(ROOT)} ({len(files)} public files).')
