#!/usr/bin/env python3
"""Check aggregate platform routing without compiling or skipping native failures."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='notchx-test-routing-') as directory:
    directory = Path(directory)
    log = directory / 'commands'
    # Commands are test doubles only for this routing test. The real aggregate
    # still executes source checks and xcodebuild under its normal environment.
    for command, script in {
        'uname': '#!/bin/sh\nprintf "%s\\n" "$TEST_PLATFORM"\n',
        'python3': '#!/bin/sh\nprintf "python3 %s\\n" "$*" >> "$TEST_ROUTE_LOG"\n',
        'bash': '#!/bin/sh\nprintf "bash %s\\n" "$*" >> "$TEST_ROUTE_LOG"\nif [ "$1" = scripts/test-native.sh ]; then exit "$TEST_NATIVE_EXIT"; fi\n',
    }.items():
        path = directory / command
        path.write_text(script)
        path.chmod(0o755)

    def run(platform, native_exit=0):
        log.write_text('')
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/test.sh')], cwd=ROOT,
            env={**os.environ, 'PATH': str(directory) + os.pathsep + os.environ['PATH'],
                 'TEST_PLATFORM': platform, 'TEST_ROUTE_LOG': str(log),
                 'TEST_NATIVE_EXIT': str(native_exit)}, capture_output=True, text=True)
        return result.returncode, log.read_text().splitlines()

    status, commands = run('Linux')
    assert status == 0
    assert 'python3 scripts/test-agent-host.py' in commands
    assert 'bash scripts/test-native.sh' not in commands

    status, commands = run('Darwin')
    assert status == 0
    assert 'python3 scripts/test-agent-host.py' in commands
    assert commands[-1] == 'bash scripts/test-native.sh'

    status, commands = run('Darwin', native_exit=37)
    assert commands[-1] == 'bash scripts/test-native.sh'
    assert status == 37, 'The aggregate must fail when native XCTest fails'

print('PASS: aggregate runs native XCTest only on macOS and propagates native failures')
