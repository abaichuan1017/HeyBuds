"""Create and inspect read-only macOS application disk images."""
from contextlib import contextmanager
from pathlib import Path
import os
import plistlib
import subprocess
import tempfile


@contextmanager
def mounted(image):
    with tempfile.TemporaryDirectory(prefix='HeyBuds-dmg-') as directory:
        mountpoint = Path(directory) / 'volume'
        mountpoint.mkdir()
        result = subprocess.check_output([
            'hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
            '-plist', '-mountpoint', str(mountpoint), str(Path(image).resolve()),
        ])
        entities = plistlib.loads(result)['system-entities']
        volume = next(Path(e['mount-point']) for e in entities if 'mount-point' in e)
        assert volume.resolve() == mountpoint.resolve(), 'Unexpected disk-image mount point'
        try:
            yield volume
        finally:
            subprocess.run(['hdiutil', 'detach', str(volume)], check=True, stdout=subprocess.PIPE)


def create(app, output):
    app, output = Path(app).resolve(), Path(output).resolve()
    assert app.is_dir() and app.suffix == '.app', 'Expected an application bundle'
    assert output.suffix == '.dmg', 'Expected a DMG output'
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.HeyBuds-dmg-', dir=output.parent) as directory:
        stage = Path(directory)
        contents = stage / 'contents'
        contents.mkdir()
        subprocess.run(['ditto', '--norsrc', '--noextattr', '--noqtn', str(app), str(contents / app.name)], check=True)
        (contents / 'Applications').symlink_to('/Applications')
        image = stage / output.name
        subprocess.run([
            'hdiutil', 'create', '-quiet', '-volname', app.stem, '-srcfolder', str(contents),
            '-fs', 'HFS+', '-format', 'UDZO', '-imagekey', 'zlib-level=9', str(image),
        ], check=True)
        subprocess.run(['hdiutil', 'verify', '-quiet', str(image)], check=True)
        os.replace(image, output)
    print(f'Created {output.name}')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    create(args.app, args.output)
