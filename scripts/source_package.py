"""Public source allowlist shared by the auditor and archive builder."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOP_LEVEL = (
    '.gitignore', 'AGENTS.md', 'Package.swift', 'README.md', 'README_EN.md',
    'LICENSE', 'THIRD_PARTY_NOTICES.md', 'CHANGELOG.md', 'CONTRIBUTING.md',
)
DIRECTORIES = ('Sources', 'Tests', 'scripts', 'docs', 'Licenses', '.github')
EXCLUDED_PARTS = {'.DS_Store', '__pycache__', '.git', 'xcuserdata'}


def public_files(root=ROOT):
    result = []
    for name in TOP_LEVEL:
        path = root / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f'Missing or non-regular public file: {name}')
        result.append(path)
    for name in DIRECTORIES:
        directory = root / name
        if not directory.is_dir() or directory.is_symlink():
            raise ValueError(f'Missing or non-regular public directory: {name}')
        for path in sorted(directory.rglob('*')):
            if path.is_symlink():
                raise ValueError(f'Symlink is not allowed in source archives: {path.relative_to(root)}')
            if path.is_file() and not set(path.relative_to(root).parts).intersection(EXCLUDED_PARTS) and not path.name.startswith('._'):
                result.append(path)
    return sorted(result, key=lambda path: path.relative_to(root).as_posix())
