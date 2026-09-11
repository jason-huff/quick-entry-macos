"""Optional, explicitly configured AI adapter; no network access by default.

QUICK_ENTRY_AGENT names an executable (not a shell command). It receives the
bounded prompt on stdin and returns JSON on stdout. Its model/context policy is
owned by the user. The app never supplies a private vault or browses other files.
"""
import os
import shutil
import subprocess
import tempfile


def run_agent(prompt):
    configured = os.environ.get('QUICK_ENTRY_AGENT', '')
    if not configured:
        return None
    executable = shutil.which(os.path.expanduser(configured))
    if not executable:
        return None
    try:
        # Isolate execution from the source/data directory, and do not interpret
        # captures as command-line options or shell syntax.
        with tempfile.TemporaryDirectory(prefix='quick-entry-agent-') as cwd:
            result = subprocess.run([executable], input=prompt, text=True,
                                    capture_output=True, cwd=cwd, timeout=180,
                                    check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 else None
