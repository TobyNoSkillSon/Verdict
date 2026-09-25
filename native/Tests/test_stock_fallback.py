"""Real-weights stock fallback, Laya and Von, through isolated bench/runtimes.py helpers (never the app).

VERDICT_VON_PARITY=1 python3 -m unittest -v native.Tests.test_stock_fallback
The test-only hook VERDICT_TEST_OPTIMIZED_FAULT makes the optimized path fail during inference (non-finite logits,
or a throw). The request must still succeed with the stock path's answers — identical to a helper started on the
stock path (VERDICT_STOCK_PATH=1) — and /status must flip the model's engine to 'mlx' with the reason.
"""
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'bench'))
HELPER = Path(os.environ.get('VERDICT_HELPER', ROOT / 'native/.build/release-helper/verdict-helper'))
QUESTIONS = {'refund': {'type': 'noul', 'instructions': 'Does the writer ask for money back?'},
             'topic': {'type': 'choice', 'instructions': 'Which section?', 'criteria': {'biz': 'business', 'sport': 'sports', 'other': 'anything else'}},
             'urgency': {'type': 'score', 'instructions': 'How urgent is it?', 'criteria': ['not', 'somewhat', 'very']}}
# A long item (> 768 tokens) so the windowed-attention path is part of what fails and what the stock rerun replaces.
ITEMS = ['Refund my order, it arrived broken.', 'Apple shares rose 4% after record iPhone sales.',
         ' '.join(['The quarterly report covers revenue, margins, hiring and the outlook for next year.'] * 90)]


@unittest.skipUnless(os.environ.get('VERDICT_VON_PARITY') == '1', 'Set VERDICT_VON_PARITY=1 for GPU tests')
class StockFallbackGPUTests(unittest.TestCase):
    def run_helper(self, model, env):
        import runtimes
        ok, why = runtimes.availability(model, 'swift', str(HELPER))
        if not ok:
            self.skipTest(why)

        class Runtime(runtimes.HttpRuntime):
            def env(self):
                return dict(super().env(), **env)
        rt = Runtime(model, 'swift', str(HELPER), bits=16 if model.startswith('von') else 0)
        try:
            rt.start(); rt.load()
            before = rt.call('/status')['models'][model]
            results = rt.call('/judge', {'items': ITEMS, 'questions': QUESTIONS, 'model': model})['results']
            after = rt.call('/status')['models'][model]
            again = rt.call('/judge', {'items': ITEMS[:1], 'questions': QUESTIONS, 'model': model})['results']
            return before, results, after, again, rt
        finally:
            rt.close()

    def test_fallback_answers_match_stock_and_label_flips(self):
        for model in ('laya-english', 'von-1.2'):
            _, reference, stock, _, _ = self.run_helper(model, {'VERDICT_STOCK_PATH': '1'})
            self.assertEqual(stock['engine'], 'mlx')
            _, optimized, plain, _, _ = self.run_helper(model, {})
            self.assertEqual(plain['engine'], 'optimized', plain)
            for fault in ('nan', 'throw'):
                with self.subTest(model=model, fault=fault):
                    before, results, after, again, rt = self.run_helper(model, {'VERDICT_TEST_OPTIMIZED_FAULT': fault})
                    self.assertEqual(before['engine'], 'optimized')
                    self.assertTrue(all('answers' in r for r in results), results)
                    self.assertEqual([r['answers'] for r in results], [r['answers'] for r in reference])
                    self.assertEqual([r['answers'] for r in again], [r['answers'] for r in reference[:1]])
                    self.assertEqual(after['engine'], 'mlx')
                    self.assertIn('failed during inference', after['engine_reason'])
                    self.assertEqual((after['optimizations']['tokenizer'], after['optimizations']['attention']), ('library', 'stock'))
                    log = (Path(runtimes_logs()) / f'{rt.key}.stderr.log').read_text()
                    self.assertEqual(log.count(f'"stock_fallback":"{model}"'), 1, log[-600:])
            # Sanity: stock and optimized agree on the choices (the optimized path is validated at load).
            self.assertEqual([r['answers']['topic']['choice'] for r in optimized], [r['answers']['topic']['choice'] for r in reference])


class RequestErrorGPUTests(unittest.TestCase):
    """A request that fails on its own merits (it fails on the stock path too) must not switch the model to stock."""
    @unittest.skipUnless(os.environ.get('VERDICT_VON_PARITY') == '1', 'Set VERDICT_VON_PARITY=1 for GPU tests')
    def test_bad_request_keeps_optimized(self):
        import runtimes
        ok, why = runtimes.availability('von-1.2', 'swift', str(HELPER))
        if not ok:
            self.skipTest(why)
        rt = runtimes.HttpRuntime('von-1.2', 'swift', str(HELPER), bits=16)
        try:
            rt.start(); rt.load()
            with self.assertRaises(RuntimeError) as cm:     # Von reserves its mask token: refused on either path
                rt.call('/judge', {'items': ['x'], 'questions': {'q': {'type': 'noul', 'instructions': 'Is [MASK] here?'}}, 'model': 'von-1.2'})
            self.assertIn('mask token', str(cm.exception))
            self.assertEqual(rt.call('/status')['models']['von-1.2']['engine'], 'optimized')
            good = rt.call('/judge', {'items': ITEMS[:1], 'questions': QUESTIONS, 'model': 'von-1.2'})['results'][0]
            self.assertIn('answers', good)
            self.assertEqual(rt.call('/status')['models']['von-1.2']['engine'], 'optimized')
            key = rt.key
        finally:
            rt.close()
        self.assertNotIn('stock_fallback', (Path(runtimes_logs()) / f'{key}.stderr.log').read_text())


def runtimes_logs():
    import runtimes
    return runtimes.CACHE / 'logs/runtime'


if __name__ == '__main__':
    unittest.main()
