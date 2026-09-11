import importlib.util
from pathlib import Path
import tempfile
import unittest

class HiringTests(unittest.TestCase):
    def test_hiring_priority_waiting_and_section_boundaries(self):
        spec = importlib.util.spec_from_file_location('ranker', Path(__file__).resolve().parents[1] / 'refresh-hyperd-todos.py')
        ranker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ranker)
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state.md'
            state.write_text('''## Hiring — active
### Immediate outreach
- [ ] Send portfolio screen
- [x] Completed screen
### Active pipeline and sourcing
- [ ] Review candidate feedback
### Waiting on recruiter / not owned yet
- Recruiter is arranging a chat.
- [ ] Recruiter-owned follow-up
## Owing
- [ ] Review release
## Done
- [ ] Not active
''')
            ranker.STATE_OF_THE_UNION = state
            ranker.TODO_PROCESSING = Path(directory) / 'missing.md'
            ranker.INBOX_REVIEW_PATH = Path(directory) / 'missing.json'
            tasks = ranker.candidates()
            self.assertEqual([t['source'] for t in tasks], ['hiring', 'hiring', 'owing'])
            self.assertEqual(tasks[0]['text'], 'Send portfolio screen')
            selected, _ = ranker.fallback_recommendations(tasks)
            self.assertEqual(selected[0]['id'], tasks[0]['id'])
            state.write_text('## Owing\n- [ ] Review release\n')
            self.assertEqual(len(ranker.candidates()), 1)

if __name__ == '__main__':
    unittest.main()
