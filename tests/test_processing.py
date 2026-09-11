"""Regression tests use fake agent responses and temporary files only."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

class IncrementalReviewTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('review', Path(__file__).resolve().parents[1] / 'preprocess-inbox.py')
        self.review = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.review)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.review.TODO_PATH = Path(self.temp.name) / 'inbox.md'
        self.review.CACHE_PATH = Path(self.temp.name) / 'cache.json'
        self.calls = []
        def agent(captures):
            self.calls.append(captures)
            return [{'id': item['id'], 'classification': 'note' if item['text'].startswith('Thought') else 'todo', 'text': item['text']} for item in captures]
        self.review.agent_review = agent

    def run_review(self, *texts):
        raw = '## Inbox\n' + ''.join(f'- [ ] {text}\n' for text in texts) + '\n## Processed\n'
        self.review.TODO_PATH.write_text(raw)
        with contextlib.redirect_stdout(io.StringIO()):
            self.review.main()
        self.assertEqual(self.review.TODO_PATH.read_text(), raw)
        return json.loads(self.review.CACHE_PATH.read_text())

    def test_only_new_and_changed_captures_go_to_agent(self):
        initial = self.run_review('Send the brief', 'Thought about the design')
        self.assertEqual(initial['non_actionable_count'], 1)
        same = self.run_review('Send the brief', 'Thought about the design')
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(same['submitted_count'], 0)
        self.run_review('Send the brief', 'Thought about the design', 'Book the review')
        self.assertEqual([c['text'] for c in self.calls[-1]], ['Book the review'])
        self.run_review('Send the revised brief', 'Thought about the design')
        self.assertEqual([c['text'] for c in self.calls[-1]], ['Send the revised brief'])

    def test_agent_failure_preserves_review_and_new_capture(self):
        self.run_review('Thought about the design')
        self.review.agent_review = lambda _: None
        result = self.run_review('Thought about the design', 'Send the brief')
        self.assertEqual(result['non_actionable_count'], 1)
        self.assertEqual(len(result['items']), 2)
        self.assertEqual(len(result['reviewed_ids']), 1)

    def test_partial_results_are_retried_not_hidden(self):
        self.review.agent_review = lambda _: []
        result = self.run_review('Send the brief')
        self.assertEqual(result['reviewed_ids'], [])
        self.assertEqual(result['items'][0]['text'], 'Send the brief')

    def test_empty_inbox_does_not_invoke_agent(self):
        self.run_review()
        self.assertEqual(self.calls, [])

    def test_batch_limit_and_duplicates(self):
        result = self.run_review(*(f'Send brief {i}' for i in range(170)))
        self.assertEqual(len(self.calls[0]), 160)
        self.assertEqual(len(result['items']), 170)
        self.run_review(*(f'Send brief {i}' for i in range(170)))
        self.assertEqual(len(self.calls[-1]), 10)

if __name__ == '__main__':
    unittest.main()
