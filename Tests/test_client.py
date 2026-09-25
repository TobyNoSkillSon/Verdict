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

class PrecisionTests(unittest.TestCase):
    def test_deltas_match_the_app(self):
        from verdict import deltas
        base = {'accuracy': 0.561, 'ece': 0.117, 'ms': 4.6, 'j_per_1k': 380}
        self.assertEqual(deltas({'accuracy': 0.557, 'ece': 0.129, 'ms': 3.4, 'j_per_1k': 304}, base),
                         {'accuracy': '\u22120.4 pt', 'ece': '+0.012', 'speed': '35% faster', 'energy': '20% less energy'})
        self.assertEqual(deltas({'ms': 5.52, 'j_per_1k': 437}, base), {'speed': '20% slower', 'energy': '15% more energy'})
        self.assertEqual(deltas({'ms': 4.6}, {'ms': 14.2}), {'speed': '3.1\u00d7 faster'})
        self.assertEqual(deltas({}, base), {})
        self.assertEqual(deltas({'j_per_1k': 1100.2}, {'j_per_1k': 378.6}), {'energy': '2.9\u00d7 more energy'})
        self.assertEqual(deltas({'j_per_1k': 740}, {'j_per_1k': 380}), {'energy': '95% more energy'})

    def test_both_benchmark_shapes(self):
        from verdict import _precisions
        self.assertEqual(_precisions({'accuracy': 0.7, 'source': 'published'}, 16), (16, {16: {'accuracy': 0.7, 'source': 'published'}}))
        self.assertEqual(_precisions({'default_bits': 32, 'precisions': {'32': {'accuracy': 0.5}, '8': 'bad', 'x': {}}}, 32), (32, {32: {'accuracy': 0.5}}))
        self.assertEqual(_precisions(None, 32), (32, {}))

    def test_recommended_rule_mirrors_core(self):
        from verdict import recommended_bits as rec
        R = lambda acc=None, ms=None, j=None: {k: v for k, v in (('accuracy', acc), ('ms', ms), ('j_per_1k', j)) if v is not None}
        self.assertEqual(rec({16: R(0.554, 8.2, 422), 8: R(0.551, 9.9, 470), 4: R(0.548, 9.6, 300)}), 16)   # 4 is 0.6 pt down
        self.assertEqual(rec({32: R(0.485, 15, 1050), 16: R(0.480, 7.4, 345)}), 16)                           # exactly 0.5 pt: within
        self.assertEqual(rec({16: R(0.5, 8, 400), 8: R(0.5, 7, 400)}), 8)                                     # energy tie -> ms
        self.assertEqual(rec({16: R(0.5, 7, 400), 8: R(0.5, 7, 400)}), 16)                                    # full tie -> higher bits
        self.assertEqual(rec({16: R(0.5, 8, 400), 8: R(None, 3, 100)}), 16)                                   # no accuracy: unmeasured
        self.assertEqual(rec({16: R(0.5, 8), 8: R(0.5, 9, 900)}), 8)                                          # missing energy ranks last
        self.assertEqual(rec({16: R(0.5, 8), 8: R(0.5, 6)}), 8)
        self.assertEqual(rec({16: R(0.5), 8: R(0.5)}), 16)
        self.assertEqual(rec({32: R(0.588)}), 32)                                                             # one measured precision
        self.assertIsNone(rec({16: R(None, 4)}))
        self.assertIsNone(rec({}))
        self.assertEqual(rec({16: R(0.5, j=400), 2: R(0.5, j=10)}, [16, 8, 4]), 16)                           # offered options only

    def test_shipped_defaults_follow_the_rule(self):
        import json
        from verdict import recommended_bits, _precisions, native_bits, precision_options
        root = Path(__file__).resolve().parents[1]
        bench = json.loads((root / 'Resources/benchmarks.json').read_text())
        seen = {}
        for m in json.loads((root / 'Resources/models.json').read_text()):
            if m.get('reference'):
                self.assertNotIn('default_bits', m); continue
            _, results = _precisions(bench.get(m['id']), native_bits(m.get('runtime')))
            seen[m['id']] = recommended_bits(results, precision_options(m.get('runtime')))
            self.assertEqual(m['default_bits'], seen[m['id']], m['id'])                    # what the helper loads
            self.assertEqual(bench[m['id']]['default_bits'], seen[m['id']], m['id'])       # catalog data
        self.assertEqual(seen, {'laya-english': 16, 'laya-multilingual': 16, 'laya-typed-decisions': 16, 'von-1.2': 16, 'von-1.1': 4})

    def test_models_default_to_recommended(self):
        import json
        root = Path(__file__).resolve().parents[1]
        catalog = json.loads((root / 'Resources/models.json').read_text())
        saved = verdict.status, verdict._selected_precision
        try:
            verdict.status = lambda: {'catalog': catalog, 'models': {'von-1.2': {'bits': 16}}, 'installed': {}}
            verdict._selected_precision = lambda: {}
            ms = {m['id']: m for m in verdict.models()}
            von = ms['von-1.2']
            self.assertEqual(von['precision'], {'selected': 16, 'default': 16, 'loaded': 16, 'options': [32, 16, 8, 4]})
            self.assertEqual(von['benchmarks']['32']['deltas'], {'accuracy': '+0.1 pt', 'ece': '\u22120.001',
                                                                 'speed': '2.0\u00d7 slower', 'energy': '2.9\u00d7 more energy'})
            self.assertNotIn('deltas', von['benchmarks']['16'])
            self.assertEqual(ms['von-1.1']['precision']['selected'], 4)
            self.assertEqual(ms['laya-english']['precision']['selected'], 16)
            self.assertIsNone(ms['jev']['precision'])
            verdict._selected_precision = lambda: {'von-1.2': 0, 'laya-english': 8}          # explicit choices win
            ms = {m['id']: m for m in verdict.models()}
            self.assertEqual(ms['von-1.2']['precision']['selected'], 32)
            self.assertEqual(ms['laya-english']['precision']['selected'], 8)
        finally:
            verdict.status, verdict._selected_precision = saved

if __name__ == '__main__': unittest.main()
