import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from agent_runner import run_agent
import importlib.util

class AgentAdapterTests(unittest.TestCase):
    def test_default_has_no_agent(self):
        with patch.dict(os.environ, {'QUICK_ENTRY_AGENT': ''}):
            self.assertIsNone(run_agent('Sensitive capture'))

    def test_prompt_is_stdin_not_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            adapter = Path(directory) / 'test adapter'
            adapter.write_text('#!/bin/sh\n/bin/cat\n')
            adapter.chmod(0o700)
            with patch.dict(os.environ, {'QUICK_ENTRY_AGENT': str(adapter)}):
                self.assertEqual(run_agent('$(do-not-execute)\n--help'), '$(do-not-execute)\n--help')

    def test_ranker_accepts_only_existing_ids_and_no_duplicates(self):
        spec = importlib.util.spec_from_file_location('ranker', Path(__file__).resolve().parents[1] / 'refresh-hyperd-todos.py')
        ranker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ranker)
        with patch.object(ranker, 'run_agent', return_value=json.dumps({'items': [{'id': 'unknown'}, {'id': 'a'}, {'id': 'a'}]})):
            ranked, _ = ranker.agent_recommendations([{'id': 'a', 'text': 'Read brief', 'source': 'inbox'}], '')
        self.assertEqual([r['id'] for r in ranked], ['a'])

if __name__ == '__main__':
    unittest.main()
