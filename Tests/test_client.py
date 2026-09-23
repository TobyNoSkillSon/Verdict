"""Client surface tests: question builders, answer wrappers, lint. No worker needed."""
import sys, unittest, warnings
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'client'))
import verdict
from verdict import Choice, Score, Noul, Result, lint

class ClientTests(unittest.TestCase):
    def test_question_builders_match_wire_format(self):
        self.assertEqual(Choice('q', a='x', b='y'), {'type': 'choice', 'instructions': 'q', 'criteria': {'a': 'x', 'b': 'y'}})
        self.assertEqual(Choice('q', ['a', 'b']), {'type': 'choice', 'instructions': 'q', 'criteria': {'a': 'a', 'b': 'b'}})
        self.assertEqual(Score('q', ['lo', 'hi']), {'type': 'score', 'instructions': 'q', 'criteria': ['lo', 'hi']})
        self.assertEqual(Noul('q'), {'type': 'noul', 'instructions': 'q'})
    def test_answers_compare_like_values(self):
        r = Result({'answers': {'dept': {'choice': 'billing', 'confidence': 0.9, 'probabilities': {'billing': 0.9, 'other': 0.1}},
                                'refund': {'noul': 0.86, 'confidence': 0.86}, 'urg': {'score': 1.6, 'confidence': 0.4}}, 'model': 'm', 'ms': 6.0})
        self.assertTrue(r.dept == 'billing' and r.refund > 0.7 and r.urg >= 1.5 and bool(r.refund))
        self.assertEqual(r.dept.probabilities['billing'], 0.9); self.assertEqual(r['refund'].noul, 0.86)
        self.assertEqual(r['answers']['dept']['choice'], 'billing')   # dict-style still works
        self.assertTrue(r); self.assertIsNone(r.error)
        with self.assertRaises(AttributeError): r.missing
    def test_error_result_is_falsy(self):
        r = Result({'error': 'too long', 'model': 'm', 'ms': 0}); self.assertFalse(r); self.assertEqual(r.answers, {})
    def test_lint_flags_bad_shapes_only(self):
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter('always')
            lint({'ok': Choice('q', a='x', other='none of these'), 'ok2': Noul('Is it remote?'), 'ok3': Score('q', ['no deadline', 'blocking today'])})
            self.assertEqual(w, [])
            lint({'a': Choice('q', a='x', b='y'), 'b': Noul('how many?'), 'c': Score('q', ['low', 'high']), 'd': Noul('urgent and billing?'),
                  'e': Choice('q', {str(i): str(i) for i in range(25)})})
            self.assertEqual(len(w), 6)  # 25 options is two problems: count and no escape option

class CatalogTests(unittest.TestCase):
    def test_every_model_has_links(self):
        import json
        cat = json.loads((Path(__file__).resolve().parents[1] / 'Resources/models.json').read_text())
        for m in cat:
            self.assertTrue(m.get('links', {}).get('upstream'), m['id'])
            if m.get('repository'):
                self.assertTrue(m['links'].get('weights', '').startswith('https://huggingface.co/'), m['id'])

if __name__ == '__main__': unittest.main()
