#!/usr/bin/env python3
"""Prepare the pinned iPhone Pipecat runtime without model or audio assets."""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / '.build/pipecat-ios'
REVISION = '6a204432df5cd533abb85e0577a7e79dccd93a04'


def run(*args):
    subprocess.run(list(map(str, args)), check=True)


def main():
    if not REFERENCE.exists():
        run('git', 'clone', 'https://github.com/pipecat-ai/pipecat-build-ios', REFERENCE)
        run('git', '-C', REFERENCE, 'checkout', '--detach', REVISION)
    actual = subprocess.check_output(['git', '-C', str(REFERENCE), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != REVISION:
        raise SystemExit('Unexpected Pipecat reference revision; use the pinned checkout.')
    run('uv', 'sync', '--locked', '--group', 'native', '--project', REFERENCE)
    python = REFERENCE / '.venv/bin/python'
    if Path(sys.executable).resolve() != python.resolve():
        run(python, __file__)
        return
    import tarfile
    sys.path.insert(0, str(REFERENCE / 'scripts'))
    import setup as reference
    from build_options import write_build_options
    write_build_options(False)
    if not (REFERENCE / 'Vendor/Python.xcframework').exists():
        (REFERENCE / 'Vendor').mkdir(exist_ok=True)
        with tarfile.open(reference.fetch(reference.PYTHON_URL, reference.PYTHON_SHA256)) as archive:
            archive.extractall(REFERENCE / 'Vendor', members=[m for m in archive.getmembers()
                if m.name.startswith('Python.xcframework/') or m.name == 'VERSIONS'], filter='data')
    if not (REFERENCE / '.build/pydantic_core-2.46.5').exists():
        with tarfile.open(reference.fetch(reference.CORE_URL, reference.CORE_SHA256)) as archive:
            archive.extractall(REFERENCE / '.build', filter='data')
    run('rustup', 'target', 'add', 'aarch64-apple-ios')
    # Cargo's encoded flags preserve workspace paths containing spaces.
    os.environ['CARGO_ENCODED_RUSTFLAGS'] = '\x1f'.join([
        '-L', 'framework=' + str(REFERENCE / 'Vendor/Python.xcframework/ios-arm64'),
        '-l', 'framework=Python', '-C', 'link-arg=-Wl,-headerpad_max_install_names'])
    run(python, REFERENCE / 'scripts/build_native.py', '--platform', 'device', '--disable-phonon')
    run(python, REFERENCE / 'scripts/stage_python.py')
    run('uv', 'pip', 'install', '--python', python, '--no-deps', '--no-build-isolation', '-e', REFERENCE / 'pipecat')


if __name__ == '__main__':
    main()
