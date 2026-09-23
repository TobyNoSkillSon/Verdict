"""Worker protocol tests with a stub model: no downloads, no MLX."""
import json, os, subprocess, sys, tempfile, time, unittest, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

STUB = '''
import sys, types
m = types.ModuleType("laya_mlx")
class _Enc:
    def __init__(self, ids): self.ids = ids
class _Backend:
    def encode(self, text): return _Enc(list(range(len(text.split()))))
class _Tok:
    backend = _Backend()
class Agent:
    tok = _Tok(); cfg = {"max_len": 512}; model = None
    def predict(self, state, questions):
        out = {}
        for k, q in questions.items():
            if q["type"] == "noul": out[k] = {"noul": 0.75, "confidence": 0.75}
            elif q["type"] == "choice": out[k] = {"choice": list(q["criteria"])[0], "confidence": 0.9, "probabilities": {c: 0.1 for c in q["criteria"]}}
            else: out[k] = {"score": 1.0, "confidence": 0.5}
        return {"answers": out}
m.load = lambda *a, **k: Agent()
sys.modules["laya_mlx"] = m
hub = types.ModuleType("huggingface_hub"); hub.try_to_load_from_cache = lambda *a, **k: None; sys.modules["huggingface_hub"] = hub
sys.argv = ["worker.py"]
exec(compile(open(sys.argv_path).read(), sys.argv_path, 'exec'), {'__file__': sys.argv_path, '__name__': '__main__'})
'''

class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.support = Path(self.tmp.name)
        env = dict(os.environ, VERDICT_SUPPORT_DIR=str(self.support), VERDICT_PRELOAD='laya-english', **getattr(self, 'extra_env', {}))
        runner = self.support / 'run.py'
        runner.write_text('import sys\nsys.argv_path = %r\n' % str(HERE / 'Resources/worker.py') + STUB)
        self.proc = subprocess.Popen([sys.executable, str(runner)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = self.proc.stdout.readline(); self.port = json.loads(line)['port']
        for _ in range(50):
            try:
                if 'laya-english' in json.loads((self.support / 'status.json').read_text())['models']: break
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(0.1)
    def tearDown(self):
        self.call('POST', '/quit'); self.proc.wait(5); self.tmp.cleanup()
    def call(self, method, path, body=None):
        req = urllib.request.Request(f'http://127.0.0.1:{self.port}{path}', method=method, data=json.dumps(body).encode() if body else None, headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=10) as r: return json.loads(r.read())
    def status(self): return self.call('GET', '/status')
    def test_status_file_and_preload(self):
        s = json.loads((self.support / 'status.json').read_text())
        self.assertEqual(s['port'], self.port); self.assertIn('laya-english', s['models'])
    def test_judge_batches_and_counts(self):
        r = self.call('POST', '/judge', {'items': ['a', {'b': 1}], 'questions': {'x': {'type': 'noul', 'instructions': 'q'}}})
        self.assertEqual(len(r['results']), 2); self.assertEqual(r['results'][0]['answers']['x']['noul'], 0.75)
        self.assertEqual(self.status()['items'], 2)
    def test_routes_non_ascii_to_multilingual(self):
        r = self.call('POST', '/judge', {'items': ['zażółć gęślą jaźń'], 'questions': {'x': {'type': 'noul', 'instructions': 'q'}}})
        self.assertEqual(r['results'][0]['model'], 'laya-multilingual')
    def test_bad_requests(self):
        with self.assertRaises(urllib.error.HTTPError): self.call('POST', '/judge', {'items': [], 'questions': {}})
        with self.assertRaises(urllib.error.HTTPError): self.call('POST', '/load', {'model': 'nope'})
    def test_overlong_item_refused_not_truncated(self):
        items = ['short one', ' '.join(['word'] * 9000)]
        r = self.call('POST', '/judge', {'items': items, 'questions': {'x': {'type': 'noul', 'instructions': 'q'}}})
        self.assertIn('noul', r['results'][0]['answers']['x'])
        self.assertIn('error', r['results'][1]); self.assertIn('8192', r['results'][1]['error'])
    def test_shed_keeps_first_model(self):
        self.call('POST', '/load', {'model': 'laya-multilingual'})
        self.assertEqual(len(self.status()['models']), 2)
        r = self.call('POST', '/shed'); self.assertEqual(r['loaded'], ['laya-english'])
    def test_unload(self):
        self.call('POST', '/unload', {'model': 'laya-english'}); self.assertEqual(self.status()['models'], {})

if __name__ == '__main__': unittest.main()
