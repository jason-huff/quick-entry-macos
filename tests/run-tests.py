#!/usr/bin/env python3
"""Compile real AppKit components with an isolated fixture harness (no install)."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]) if len(sys.argv) > 1 else repo / 'QuickEntry.swift'
root = Path(tempfile.mkdtemp(prefix='quick-entry-tests-'))
combined = root / 'ViewerTests.swift'
combined.write_text(source.read_text().replace('@main\n', '', 1) + '\n' + (repo / 'tests/ViewerTests.swift').read_text())
binary = root / 'viewer-tests'
subprocess.run(['swiftc', '-gnone', '-parse-as-library', str(combined), '-o', str(binary), '-framework', 'AppKit', '-framework', 'Carbon', '-framework', 'CryptoKit'], check=True)
env = {**os.environ, 'TEST_ROOT': str(root), 'CASE_ROOT': str(root), 'QUICK_ENTRY_ROOT': str(root), 'QUICK_ENTRY_TODO_FILE': str(root / 'todo-processing.md'), 'QUICK_ENTRY_STATE_FILE': str(root / 'state-of-the-union.md')}
subprocess.run([str(binary)], env=env, check=True)
