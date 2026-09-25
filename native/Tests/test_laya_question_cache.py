"""Laya's cross-request question-template cache must key by exact bytes, not canonical equivalence.

VERDICT_LAYA_FULL_REGRESSION=1 VERDICT_LAYA_CACHE=$HOME/.cache/huggingface/hub python3 -m unittest -v native.Tests.test_laya_question_cache

The Multilingual tokenizer has no normalizer, so an NFC and an NFD spelling of the same question are
different inputs (different token IDs, different answers). A String-keyed cache folded them: after the
NFC spelling was judged, the NFD spelling got the NFC answer (0.6743 instead of 0.4881). GPU; isolated
helpers; local weights only.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unicodedata
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get('VERDICT_HELPER', ROOT / 'native/.build/release-helper/verdict-helper'))
CACHE = Path(os.environ.get('VERDICT_LAYA_CACHE', Path.home() / '.cache/huggingface/hub'))
MODEL = 'laya-multilingual'
TEXT = 'Zamówiłem kawę w kawiarni, ale kelner przyniósł herbatę. Chcę zwrotu pieniędzy.'
INSTRUCTIONS = 'Czy klient prosi o zwrot pieniędzy za zamówienie w café?'
NFC, NFD = unicodedata.normalize('NFC', INSTRUCTIONS), unicodedata.normalize('NFD', INSTRUCTIONS)


class Helper:
    def __enter__(self):
        self.support = tempfile.TemporaryDirectory(prefix='verdict-qcache-')
        env = dict(os.environ, VERDICT_SUPPORT_DIR=self.support.name, HF_HUB_CACHE=str(CACHE), HF_HUB_OFFLINE='1',
                   VERDICT_CATALOG=str(ROOT / 'Resources/models.json'), VERDICT_PRELOAD='', VERDICT_PORT='0',
                   VERDICT_PRECISION=json.dumps({MODEL: 0}))
        self.log = open(Path(self.support.name) / 'stderr.log', 'w')
        self.process = subprocess.Popen([str(BINARY)], env=env, stdout=subprocess.PIPE, stderr=self.log, text=True)
        self.base = f"http://127.0.0.1:{json.loads(self.process.stdout.readline())['port']}"
        return self

    def judge(self, questions):
        body = json.dumps({'items': [TEXT], 'questions': questions, 'model': MODEL}, ensure_ascii=False).encode()
        request = urllib.request.Request(self.base + '/judge', data=body, headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=240) as response:
            return json.load(response)['results'][0]['answers']

    def __exit__(self, *exc):
        try:
            urllib.request.urlopen(urllib.request.Request(self.base + '/quit', data=b'{}', headers={'Content-Type': 'application/json'}), timeout=10).read()
        except Exception:
            pass
        try:
            self.process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait(timeout=10)
        self.process.stdout.close(); self.log.close(); self.support.cleanup()


@unittest.skipUnless(os.environ.get('VERDICT_LAYA_FULL_REGRESSION') == '1', 'Explicit GPU fixture gate only')
class QuestionCacheCanonicalEquivalence(unittest.TestCase):
    def test_nfc_and_nfd_questions_are_distinct(self):
        self.assertNotEqual(NFC, NFD)
        with Helper() as fresh:
            expected_nfd = fresh.judge({'q': {'type': 'noul', 'instructions': NFD}})['q']
        with Helper() as warm:
            expected_nfc = warm.judge({'q': {'type': 'noul', 'instructions': NFC}})['q']
            self.assertNotEqual(expected_nfc, expected_nfd, 'fixture no longer separates the two spellings')
            self.assertEqual(warm.judge({'q': {'type': 'noul', 'instructions': NFD}})['q'], expected_nfd)
            both = warm.judge({'a': {'type': 'noul', 'instructions': NFC}, 'b': {'type': 'noul', 'instructions': NFD}})
            self.assertEqual(both['a'], expected_nfc)
            self.assertEqual(both['b'], expected_nfd)

    def test_nfc_and_nfd_choice_labels_are_two_labels(self):
        """Distinct JSON keys stay distinct labels (byte-exact, like the Python reference's dict), not a 400 or a trap."""
        labels = {unicodedata.normalize('NFC', 'café'): 'coffee order', unicodedata.normalize('NFD', 'café'): 'tea order'}
        self.assertEqual(len(labels), 2)
        with Helper() as helper:
            answer = helper.judge({'q': {'type': 'choice', 'instructions': 'Which order?', 'criteria': labels}})['q']
            self.assertEqual(sorted(answer['probabilities']), sorted(labels))
            self.assertAlmostEqual(sum(answer['probabilities'].values()), 1, delta=0.001)
            self.assertIn(answer['choice'], labels)


if __name__ == '__main__':
    unittest.main()
