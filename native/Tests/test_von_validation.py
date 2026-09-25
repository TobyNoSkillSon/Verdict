"""Von request validation and SDK input semantics (review 2026-09-25, findings 1-4). GPU, opt-in like the parity gate:

VERDICT_VON_PARITY=1 python3 -m unittest -v native.Tests.test_von_validation

Isolated helper per version over ~/.cache/verdict-bench/von/ckpt-{1.1,1.2} (symlinked snapshot, no downloads).
SDK values: von-sdk 1.1.1 / 1.2.2 through bench/von_runner.py in single (SDK evaluate) mode, 25 Sep 2026.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get('VERDICT_HELPER', ROOT / 'native/.build/release-helper/verdict-helper'))
REVISIONS = {'1.1': 'd8bb5e0745d8ee1fb65d536d6d4892d54d5a93fd', '1.2': '5df8185a4f2327ad0a7cd117cc4f701ac557b9ae'}
FILES = ('option_marker.pt', 'config.json', 'tokenizer.json', 'tokenizer_config.json', 'marker_calibration.json')

REFUND = {'q': {'type': 'noul', 'instructions': 'Does this ask for a refund?'}}
# A string that looks like JSON stays a string; dicts, numbers, bools, None and lists follow SDK _format_state.
STATE_ITEMS = ['{"message": "I want a refund"}', {'message': 'I want a refund'}, 5, 5.0, True, None,
               ['a', 1.5, {'b': None}], {'k': ['x', True]}]
SDK_STATE = {'1.1': [0.9042, 0.9471, 0.0202, 0.0038, 1.0, 0.0, 0.1989, 0.8098],
             '1.2': [0.8069, 0.8355, 0.0029, 0.1253, 0.9965, 0.0041, 0.2678, 0.7699]}
# Distinct JSON keys that Swift String equality merges (NFC vs NFD).
CANONICAL = {'q': {'type': 'choice', 'instructions': 'Pick the label', 'criteria': {'\u00e9': 'good', 'e\u0301': 'bad'}}}
CANONICAL_ITEMS = ['plain text', 'caf\u00e9 review: great coffee']
SDK_CANONICAL = {'1.1': [(0.0082, 0.9918), (0.7865, 0.2135)], '1.2': [(0.0766, 0.9234), (0.9727, 0.0273)]}
TOL = 0.0001
# Choice descriptions sent as null: the SDK describes the option by its label (desc.strip() if desc else opt.strip()).
CUSTOMER = ['I want my money back for this broken kettle', 'What time do you open on Sunday?']
NULL_DESC = {'q': {'type': 'choice', 'instructions': 'What does the customer want?',
                   'criteria': {'refund': None, 'opening hours': None, 'other': 'Anything else'}}}
SDK_NULL_DESC = {'1.1': [{'refund': 0.979, 'opening hours': 0.0095, 'other': 0.0115},
                         {'refund': 0.0344, 'opening hours': 0.8388, 'other': 0.1268}],
                 '1.2': [{'refund': 0.9722, 'opening hours': 0.008, 'other': 0.0198},
                         {'refund': 0.0062, 'opening hours': 0.9658, 'other': 0.028}]}
# Question ids that differ only by NFC/NFD are two questions (two JSON keys, two SDK answers).
NFC_ID, NFD_ID = '\u00e9', 'e\u0301'
ID_QUESTIONS = {NFC_ID: {'type': 'noul', 'instructions': 'Does the customer ask for a refund?'},
                NFD_ID: {'type': 'noul', 'instructions': 'Is this about opening hours?'}}
SDK_IDS = {'1.1': [(0.8971, 0.0222), (0.0135, 0.7834)], '1.2': [(0.821, 0.0729), (0.0403, 0.7307)]}


@unittest.skipUnless(os.environ.get('VERDICT_VON_PARITY') == '1', 'Set VERDICT_VON_PARITY=1 for Von GPU tests')
class VonValidationTests(unittest.TestCase):
    def helper(self, version):
        checkpoint = Path.home() / '.cache/verdict-bench/von' / ('ckpt-' + version)
        if not checkpoint.exists():
            self.skipTest(f'missing {checkpoint}')
        base = tempfile.TemporaryDirectory(prefix='verdict-von-validation-'); self.addCleanup(base.cleanup)
        root = Path(base.name); support = root / 'support'; support.mkdir()
        snapshot = root / 'hub/models--wfzyx--von/snapshots' / REVISIONS[version]; snapshot.mkdir(parents=True)
        for name in FILES:
            (snapshot / name).symlink_to(checkpoint / name)
        env = dict(os.environ, VERDICT_SUPPORT_DIR=str(support), HF_HUB_CACHE=str(root / 'hub'),
                   VERDICT_CATALOG=str(ROOT / 'Resources/models.json'), VERDICT_PRELOAD='', VERDICT_PORT='0',
                   VERDICT_VON_PARITY_TRACE='1')
        env.pop('MLX_ENABLE_TF32', None)
        stderr = open(support / 'stderr.log', 'w+')
        proc = subprocess.Popen([str(BINARY)], env=env, stdout=subprocess.PIPE, stderr=stderr, text=True)
        def stop():
            if proc.poll() is None:
                try: self.post('/quit', {})
                except Exception: pass
                try: proc.wait(timeout=15)
                except subprocess.TimeoutExpired: proc.kill(); proc.wait()
            proc.stdout.close(); stderr.close()
        self.addCleanup(stop)
        self.url = f'http://127.0.0.1:{json.loads(proc.stdout.readline())["port"]}'
        self.proc, self.stderr = proc, stderr
        self.model = 'von-' + version
        # SDK comparisons are f32: request native explicitly (an unset precision loads the recommended 16-bit).
        self.assertIn(self.model, self.post('/load', {'model': self.model, 'bits': 0})['loaded'])

    def post(self, route, obj):
        req = urllib.request.Request(self.url + route, data=json.dumps(obj, ensure_ascii=False).encode(),
                                     headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=300) as reply:
                return json.load(reply)
        except urllib.error.HTTPError as e:
            return {'status': e.code, **json.load(e)}

    def judge(self, items, questions):
        return self.post('/judge', {'model': self.model, 'items': items, 'questions': questions})

    def traced_lengths(self):
        self.stderr.flush(); self.stderr.seek(0)
        return [len(json.loads(line.split(' ', 1)[1])['ids']) for line in self.stderr.read().splitlines()
                if line.startswith('VON_PARITY_TRACE ')]

    def alive(self):
        self.assertIsNone(self.proc.poll(), 'helper exited')
        r = self.judge(['I want my money back'], REFUND)
        self.assertIn('noul', r['results'][0]['answers']['q'])

    def each_version(self, body):
        for version in REVISIONS:
            with self.subTest(version=version):
                self.helper(version)
                body(version)
                self.doCleanups()

    # 1 — labels
    def test_duplicate_and_canonical_labels(self):
        def body(version):
            r = self.judge(['hello'], {'q': {'type': 'choice', 'instructions': 'Pick', 'criteria': ['same', 'same']}})
            self.assertEqual((r.get('status'), r.get('error')), (400, 'Choice labels must be unique'))
            r = self.judge(['hello'], {'q': {'type': 'choice', 'instructions': 'Pick', 'criteria': {}}})
            self.assertEqual(r.get('status'), 400)
            self.alive()
            results = self.judge(CANONICAL_ITEMS, CANONICAL)['results']
            for result, (nfc, nfd) in zip(results, SDK_CANONICAL[version]):
                p = result['answers']['q']['probabilities']
                self.assertEqual(sorted(p), sorted(['\u00e9', 'e\u0301']))
                self.assertAlmostEqual(p['\u00e9'], nfc, delta=TOL); self.assertAlmostEqual(p['e\u0301'], nfd, delta=TOL)
                self.assertEqual(result['answers']['q']['choice'], '\u00e9' if nfc > nfd else 'e\u0301')
        self.each_version(body)

    # 2 — literal mask token
    def test_literal_mask_token(self):
        questions = {'choice': {'type': 'choice', 'instructions': 'Pick the label', 'criteria': {'a': 'good', 'b': 'bad'}},
                     'score': {'type': 'score', 'instructions': 'Rate it', 'criteria': ['low', 'mid', 'high']},
                     'noul': {'type': 'noul', 'instructions': 'Is this good?'}}
        def body(version):
            for kind, q in questions.items():
                # In the item: that item alone gets an error, the others are answered.
                r = self.judge(['[MASK] ' * 8, 'a fine day', 'tokenizers use [MASK] tokens'], {'q': q})['results']
                self.assertIn('literal mask token', r[0].get('error', ''), kind)
                self.assertIn('literal mask token', r[2].get('error', ''), kind)
                answer = r[1]['answers']['q']
                if 'probabilities' in answer:
                    self.assertEqual(len(answer['probabilities']), 2 if kind == 'choice' else 3)
                    self.assertAlmostEqual(sum(answer['probabilities'].values()), 1, delta=0.001)
                # In the instructions or an option description: the question is refused before any work.
                bad = dict(q, instructions=q['instructions'] + ' [MASK]')
                r = self.judge(['a fine day'], {'q': bad})
                self.assertEqual(r.get('status'), 400, kind); self.assertIn('literal mask token', r['error'])
                if kind == 'choice':
                    r = self.judge(['a fine day'], {'q': dict(q, criteria={'a': 'good [MASK]', 'b': 'bad'})})
                    self.assertEqual(r.get('status'), 400); self.assertIn('literal mask token', r['error'])
                if kind == 'score':
                    r = self.judge(['a fine day'], {'q': dict(q, criteria=['low', '[MASK]', 'high'])})
                    self.assertEqual(r.get('status'), 400); self.assertIn('literal mask token', r['error'])
                if kind == 'noul':
                    r = self.judge(['a fine day'], {'q': dict(q, criteria={'true': 'yes [MASK]', 'false': 'no'})})
                    self.assertEqual(r.get('status'), 400); self.assertIn('literal mask token', r['error'])
            self.alive()
        self.each_version(body)

    # 3 — context before any forward pass, including the cached null pass
    def test_over_context_launches_nothing(self):
        def body(version):
            before = len(self.traced_lengths())
            r = self.judge(['x'], {'q': {'type': 'noul', 'instructions': 'hello ' * 8300}})['results']
            self.assertIn('Von accepts 8192', r[0]['error'])
            self.assertEqual(self.traced_lengths()[before:], [], 'a forward pass ran for an all-over-context request')
            r = self.judge(['hello ' * 8300, 'short'], {'q': {'type': 'noul', 'instructions': 'Is this a greeting?'}})['results']
            self.assertIn('Von accepts 8192', r[0]['error']); self.assertIn('noul', r[1]['answers']['q'])
            self.assertLessEqual(max(self.traced_lengths()[before:]), 8192)
        self.each_version(body)

    # 4 — item types as the SDK's _format_state sees them
    def test_item_types_match_sdk(self):
        def body(version):
            results = self.judge(STATE_ITEMS, REFUND)['results']
            observed = [r['answers']['q']['noul'] for r in results]
            for item, got, want in zip(STATE_ITEMS, observed, SDK_STATE[version]):
                self.assertAlmostEqual(got, want, delta=TOL, msg=f'{item!r}: native {got}, SDK {want}')
        self.each_version(body)


    # Follow-up — null descriptions and normalization-distinct question ids
    def test_null_description_uses_label(self):
        def body(version):
            results = self.judge(CUSTOMER, NULL_DESC)['results']
            for result, want in zip(results, SDK_NULL_DESC[version]):
                got = result['answers']['q']['probabilities']
                self.assertEqual(sorted(got), sorted(want))
                for label in want:
                    self.assertAlmostEqual(got[label], want[label], delta=TOL, msg=f'{label}: native {got}, SDK {want}')
            # Noul criteria given as null are absent criteria (zero-shot, with the null pass).
            plain = self.judge(CUSTOMER, REFUND)['results']
            nulls = self.judge(CUSTOMER, {'q': dict(REFUND['q'], criteria={'true': None, 'false': None})})['results']
            self.assertEqual([r['answers'] for r in nulls], [r['answers'] for r in plain])
        self.each_version(body)

    def test_question_ids_are_bytes(self):
        def body(version):
            results = self.judge(CUSTOMER, ID_QUESTIONS)['results']
            for result, (nfc, nfd) in zip(results, SDK_IDS[version]):
                answers = result['answers']
                self.assertEqual(sorted(answers), sorted([NFC_ID, NFD_ID]))
                self.assertAlmostEqual(answers[NFC_ID]['noul'], nfc, delta=TOL)
                self.assertAlmostEqual(answers[NFD_ID]['noul'], nfd, delta=TOL)
        self.each_version(body)


if __name__ == '__main__':
    unittest.main()
