"""Real-weights check of the helper's default precision, through isolated bench/runtimes.py helpers (never the app).

VERDICT_VON_PARITY=1 python3 -m unittest -v native.Tests.test_default_precision
An unset Von 1.2 precision loads the catalog's recommended 16-bit weights; an explicit 0 still loads native f32.
Proof is the resident weight size: f32 holds ~4 bytes per parameter, fp16 ~2.
"""
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'bench'))
HELPER = Path(os.environ.get('VERDICT_HELPER', ROOT / 'native/.build/release-helper/verdict-helper'))


@unittest.skipUnless(os.environ.get('VERDICT_VON_PARITY') == '1', 'Set VERDICT_VON_PARITY=1 for Von GPU tests')
class DefaultPrecisionTests(unittest.TestCase):
    def weights_mb(self, bits):
        import runtimes
        ok, why = runtimes.availability('von-1.2', 'swift', str(HELPER))
        if not ok:
            self.skipTest(why)
        rt = runtimes.HttpRuntime('von-1.2', 'swift', str(HELPER), bits=bits)
        try:
            rt.start(); rt.load()
            status = rt.call('/status')
            got = status['models']['von-1.2']['bits']
            answer = rt.call('/judge', {'items': ['Refund my order, it arrived broken.'],
                                        'questions': {'r': {'type': 'noul', 'instructions': 'Does the writer ask for money back?'}},
                                        'model': 'von-1.2'})['results'][0]['answers']['r']
            self.assertTrue(0 <= answer['noul'] <= 1)
            return got, status['memory']['mlx_active_mb']
        finally:
            rt.close()

    def test_unset_loads_16_and_explicit_0_loads_f32(self):
        bits, unset_mb = self.weights_mb(None)      # no VERDICT_PRECISION entry
        self.assertEqual(bits, 16)
        bits, f32_mb = self.weights_mb(0)           # explicit native
        self.assertEqual(bits, 0)
        print('DEFAULT_PRECISION von-1.2 unset', unset_mb, 'MB; explicit 0', f32_mb, 'MB', flush=True)
        # 395M parameters: ~0.8 GB at fp16, ~1.6 GB at f32.
        self.assertLess(unset_mb, 1100)
        self.assertGreater(f32_mb, 1400)
        self.assertGreater(f32_mb / unset_mb, 1.7)


if __name__ == '__main__':
    unittest.main()
