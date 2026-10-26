#!/usr/bin/env python3
"""Audit the exact public package; no access to user preferences or hardware."""
import hashlib
import json
import re
import importlib.util
from source_package import ROOT, public_files


def audit():
    files = public_files()
    errors = []
    private_path = re.compile(r'/(?:Users|home)/[A-Za-z0-9_.-]+/')
    address = re.compile(r'(?<![A-Fa-f0-9])(?:[A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}(?![A-Fa-f0-9])')
    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        if path.suffix in {'.p12', '.pfx', '.pem', '.key', '.log', '.trace'} or path.name.startswith('.env'):
            errors.append(f'Private file type: {rel}')
        if path.suffix not in {'.swift', '.cs', '.py', '.sh', '.md', '.json', '.yml', '.yaml', '.txt'} and path.name not in {'LICENSE', '.gitignore'}:
            continue
        text = path.read_text(encoding='utf-8-sig')
        if private_path.search(text) or address.search(text):
            errors.append(f'Local home path or raw device address: {rel}')
        for kind in ('RSA', 'EC', 'OPENSSH'):
            if '-----BEGIN ' + kind + ' PRIVATE KEY-----' in text:
                errors.append(f'Private-key block: {rel}')
        if path.suffix == '.json':
            def unique(pairs):
                result = {}
                for key, value in pairs:
                    if key in result:
                        raise ValueError(f'Duplicate JSON key in {rel}: {key}')
                    result[key] = value
                return result
            json.loads(text, object_pairs_hook=unique)
        if path.suffix == '.md':
            for link in re.findall(r'\[[^\]]*\]\(([^)]+)\)', text):
                target = link.split('#')[0]
                if not target or '://' in target or target.startswith('mailto:'):
                    continue
                if not (path.parent / target).exists():
                    errors.append(f'Broken relative link in {rel}: {target}')
    package = (ROOT / 'Package.swift').read_text()
    for module in ('HeyBuds', 'HeyBudsProtocol', 'HeyBudsBluetooth', 'HeyBudsProbe'):
        if not (ROOT / 'Sources' / module).is_dir() or f'name: "{module}"' not in package:
            errors.append(f'Incorrect package module: {module}')
    build = (ROOT / 'scripts/build.sh').read_text()
    for old in ('EncoBar', 'EncoProtocol', 'EncoBluetooth', 'enco-probe', 'local.encobar.app'):
        if old in package or old in build:
            errors.append(f'Legacy branding remains in build metadata: {old}')
    version = re.search(r'static let version="([^"]+)"', (ROOT / 'Sources/HeyBuds/AppIdentity.swift').read_text()).group(1)
    for name in ('scripts/build.sh',):
        if version not in (ROOT / name).read_text():
            errors.append(f'Version mismatch: {name}')
    models = json.loads((ROOT / 'Sources/HeyBudsProtocol/Resources/MigratedModels.json').read_text())['models']
    original = json.loads((ROOT / 'Sources/HeyBudsProtocol/Resources/DeviceModels.json').read_text())['whiteList']
    overlay = json.loads((ROOT / 'Sources/HeyBudsProtocol/Resources/EncoDeckModels.json').read_text())
    sony = json.loads((ROOT / 'Sources/HeyBudsProtocol/Resources/SonyModels.json').read_text())['models']
    expansion = json.loads((ROOT / 'Sources/HeyBudsProtocol/Resources/ExpansionModels.json').read_text())['models']
    spec = importlib.util.spec_from_file_location('encodeck_import', ROOT / 'scripts/import-encodeck-x4.py')
    importer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(importer)
    if overlay != importer.catalog():
        errors.append('EncoDeck X4 catalog differs from its frozen source')
    if len(original) + len(models) + len(overlay['whiteList']) != 209 or len(sony) != 3 or len(expansion) != 16:
        errors.append('Catalog record count changed without updating release scope')
    if len({m['id'] for m in original + models + overlay['whiteList'] + sony + expansion}) != 228:
        errors.append('Duplicate catalog identifiers')
    upstream = json.loads((ROOT / 'docs/upstream-sources.json').read_text())
    resources = upstream['runtimeResourceSHA256'] | upstream['referenceResourceSHA256']
    for name, digest in resources.items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
            errors.append(f'Upstream resource changed: {name}')
    if errors:
        raise ValueError('\n'.join(errors))
    return files, version


if __name__ == '__main__':
    files, version = audit()
    print(f'Public source audit passed: HeyBuds {version}, {len(files)} files, 228 catalog records.')
