#!/usr/bin/env python3
"""Create the signed update feed for an already-built release archive."""
from pathlib import Path
import argparse
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET
from disk_image import mounted

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--notes-file', type=Path, required=True)
args = parser.parse_args()
archive = ROOT / 'dist/HeyBuds-arm64.dmg'
with mounted(archive) as volume:
    info = plistlib.loads((volume / 'HeyBuds.app/Contents/Info.plist').read_bytes())
version = re.search(r'static let version="([^"]+)"', (ROOT / 'Sources/HeyBuds/AppIdentity.swift').read_text()).group(1)
assert info['CFBundleIdentifier'] == 'local.heybuds.app' and info['CFBundleShortVersionString'] == version
tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
public_key = subprocess.check_output([str(tools / 'generate_keys'), '--account', 'HeyBuds-updates', '-p'], text=True).strip()
assert public_key == info['SUPublicEDKey'], 'Signing account does not match the application public key'
signature = subprocess.check_output([str(tools / 'sign_update'), '--account', 'HeyBuds-updates', '-p', str(archive)], text=True).strip()
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
root = ET.Element('rss', version='2.0')
channel = ET.SubElement(root, 'channel')
ET.SubElement(channel, 'title').text = 'HeyBuds'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = 'HeyBuds ' + version
ET.SubElement(item, 'link').text = f'https://github.com/abaichuan1017/HeyBuds/releases/tag/v{version}'
ET.SubElement(item, f'{{{ns}}}version').text = info['CFBundleVersion']
ET.SubElement(item, f'{{{ns}}}shortVersionString').text = version
ET.SubElement(item, f'{{{ns}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
ET.SubElement(item, 'description', {'format': 'plain-text'}).text = args.notes_file.read_text().strip()
ET.SubElement(item, 'enclosure', {
    'url': f'https://github.com/abaichuan1017/HeyBuds/releases/download/v{version}/HeyBuds-arm64.dmg',
    'length': str(archive.stat().st_size), 'type': 'application/octet-stream',
    f'{{{ns}}}edSignature': signature,
})
ET.indent(root, space='  ')
feed = ROOT / 'docs/appcast.xml'
ET.ElementTree(root).write(feed, encoding='utf-8', xml_declaration=True)
subprocess.run([str(tools / 'sign_update'), '--account', 'HeyBuds-updates', str(feed)], check=True)
subprocess.run(['swift', str(ROOT / 'scripts/verify-update.swift'), str(feed), str(archive), public_key], check=True)
print(f'Prepared signed feed for HeyBuds {version}. Keep the archive unchanged after signing.')
