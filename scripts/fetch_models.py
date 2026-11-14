#!/usr/bin/env python3
"""Fetch generic official artifacts at pinned revisions, verifying size and SHA-256."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def valid(path, item):
    if not path.exists() or path.stat().st_size != item['size']:
        return False
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() == item['sha256']


def main():
    destination = ROOT / '.local/models'
    destination.mkdir(parents=True, exist_ok=True)
    for item in json.loads((ROOT / 'config/models.json').read_text()):
        target = destination / item['filename']
        if valid(target, item):
            print('Verified:', target.name, flush=True)
            continue
        partial = target.with_suffix('.partial')
        url = f"https://huggingface.co/{item['repository']}/resolve/{item['revision']}/{item['filename']}"
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--continue-at', '-', '--output', str(partial), url], check=True)
        if not valid(partial, item):
            raise ValueError('Model size or SHA-256 mismatch; do not import ' + partial.name)
        partial.replace(target)
        print('Verified:', target.name, flush=True)


if __name__ == '__main__':
    main()
