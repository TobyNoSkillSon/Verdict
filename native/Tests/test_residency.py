"""Residency classes, per-class Keep Hot, the never-swap memory check and model context limits.

Stub models (no weights), an isolated support directory and the helper's test hooks:
  VERDICT_TEST_MEMORY_FILE     fake memory probe: {"available_mb": N} minus the estimates of loaded models
  VERDICT_BENCHMARKS           round memory_mb figures so the arithmetic below is exact
  VERDICT_TEST_MINUTE_SECONDS  seconds per Keep Hot minute; VERDICT_TEST_IDLE_TICK_S the idle-check interval

native/scripts/build-helper.sh && python3 -m unittest native.Tests.test_residency
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get('VERDICT_HELPER', ROOT / 'native/.build/release-helper/verdict-helper'))
# Estimates in MB; need = estimate + 512 MB activation headroom.
BENCH = {'laya-english': {'precisions': {'16': {'memory_mb': 1000}, '8': {'memory_mb': 600}, '4': {'memory_mb': 400}}},
         'laya-multilingual': {'precisions': {'16': {'memory_mb': 1000}}},
         'laya-typed-decisions': {'precisions': {'16': {'memory_mb': 400}}},
         'von-1.2': {'precisions': {'16': {'memory_mb': 1500}, '8': {'memory_mb': 1000}}},
         'von-1.1': {'precisions': {'16': {'memory_mb': 1500}}}}
Q = {'x': {'type': 'noul', 'instructions': 'Is it?'}}


class Helper:
    def __init__(self, available_mb=100_000, **env):
        self.dir = Path(tempfile.mkdtemp(prefix='verdict-residency-'))
        self.memory = self.dir / 'memory.json'
        self.set_available(available_mb)
        (self.dir / 'bench.json').write_text(json.dumps(BENCH))
        full = dict(os.environ, VERDICT_SUPPORT_DIR=str(self.dir), VERDICT_STUB_MODELS='1', VERDICT_PORT='0',
                    VERDICT_PRELOAD='', HF_HUB_CACHE=str(self.dir / 'hub'), VERDICT_CATALOG=str(ROOT / 'Resources/models.json'),
                    VERDICT_BENCHMARKS=str(self.dir / 'bench.json'), VERDICT_TEST_MEMORY_FILE=str(self.memory))
        for key in ('VERDICT_IDLE_MINUTES', 'VERDICT_MANUAL_IDLE_MINUTES', 'VERDICT_ON_DEMAND_IDLE_MINUTES', 'VERDICT_ALLOW_SWAP'):
            full.pop(key, None)
        full.update(env)
        self.proc = subprocess.Popen([str(BINARY)], env=full, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.port = json.loads(self.proc.stdout.readline())['port']
        if full.get('VERDICT_PRELOAD'):
            deadline = time.time() + 10
            while set(self.status()['models']) != set(full['VERDICT_PRELOAD'].split(',')) and time.time() < deadline:
                time.sleep(.05)

    def set_available(self, mb): self.memory.write_text(json.dumps({'available_mb': mb}))

    def call(self, path, body=None):
        """(HTTP status, reply)."""
        request = urllib.request.Request(f'http://127.0.0.1:{self.port}{path}', method='POST' if body is not None else 'GET',
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as e:
            with e: return e.code, json.load(e)

    def ok(self, path, body=None):
        code, reply = self.call(path, body)
        assert code == 200, (path, body, code, reply)
        return reply

    def status(self): return self.ok('/status')
    def loaded(self): return set(self.status()['models'])
    def residency(self, model): return self.status()['models'][model]['residency']
    def evicted(self): return [e['model'] for e in self.status()['evictions']]
    def judge(self, items, model='auto'): return self.ok('/judge', {'items': items, 'questions': Q, 'model': model})

    def stop(self):
        if self.proc.poll() is None:
            try: self.call('/quit', {})
            except OSError: self.proc.terminate()
            self.proc.wait(timeout=10)
        log = self.proc.stderr.read(); self.proc.stdout.close(); self.proc.stderr.close()
        shutil.rmtree(self.dir, True)
        return log


class ResidencyTests(unittest.TestCase):
    def helper(self, *args, **kwargs):
        h = Helper(*args, **kwargs)
        self.addCleanup(lambda: h.proc.poll() is None and h.stop())
        return h

    def test_residency_class_tracking(self):
        h = self.helper(VERDICT_PRELOAD='laya-english')
        self.assertEqual(h.residency('laya-english'), 'manual')                 # the launch set is manual
        h.ok('/load', {'model': 'laya-multilingual'})                         # an agent's /load: on demand
        self.assertEqual(h.residency('laya-multilingual'), 'on_demand')
        h.judge(['x'], model='von-1.2')                                       # auto-load by a request: on demand
        self.assertEqual(h.residency('von-1.2'), 'on_demand')
        h.judge(['x'], model='laya-english')                                  # using a manual model keeps it manual
        self.assertEqual(h.residency('laya-english'), 'manual')
        h.ok('/load', {'model': 'laya-multilingual', 'manual': True})         # menu Load promotes, no reload
        self.assertEqual(h.residency('laya-multilingual'), 'manual')
        h.ok('/load', {'model': 'von-1.2', 'bits': '8', 'manual': 'true'})    # the app's string body; menu Reload
        self.assertEqual((h.residency('von-1.2'), h.status()['models']['von-1.2']['bits']), ('manual', 8))
        h.ok('/load', {'model': 'von-1.2', 'bits': 16})                       # an agent reload keeps it manual
        self.assertEqual(h.residency('von-1.2'), 'manual')
        h.ok('/load', {'model': 'laya-multilingual'})                         # an agent load never demotes
        self.assertEqual(h.residency('laya-multilingual'), 'manual')
        code, reply = h.call('/load', {'model': 'laya-typed-decisions', 'manual': 'maybe'})
        self.assertEqual(code, 400); self.assertNotIn('laya-typed-decisions', h.loaded())
        # last_used per model: a request touches only the models it used.
        before = h.status()['models']
        time.sleep(.05); h.judge(['x'], model='laya-english')
        after = h.status()['models']
        self.assertGreater(after['laya-english']['last_used'], before['laya-english']['last_used'])
        self.assertEqual(after['von-1.2']['last_used'], before['von-1.2']['last_used'])
        h.ok('/unload', {'model': 'von-1.2'}); h.ok('/load', {'model': 'von-1.2'})   # a fresh load has a fresh class
        self.assertEqual(h.residency('von-1.2'), 'on_demand')
        self.assertEqual(h.evicted(), [])

    def test_fits_loads(self):
        h = self.helper(available_mb=1512)                                     # exactly estimate + headroom
        h.ok('/load', {'model': 'laya-english'})
        entry = h.status()['models']['laya-english']
        self.assertEqual(entry['memory_estimate_mb'], 1000)
        self.assertEqual(h.status()['memory']['available_mb'], 512)
        self.assertEqual(h.evicted(), [])

    def test_evicts_on_demand_lru_then_manual(self):
        h = self.helper(available_mb=3212)
        h.ok('/load', {'model': 'laya-english', 'manual': True})              # manual, oldest
        h.ok('/load', {'model': 'laya-multilingual'})                         # on demand
        h.ok('/load', {'model': 'laya-typed-decisions'})                      # on demand, 812 MB left
        h.judge(['x'], model='laya-multilingual')                             # typed-decisions is now the on-demand LRU
        # von-1.2 at 16-bit needs 2012: typed-decisions (400) is not enough, multilingual (1000) next -> 2212.
        h.ok('/load', {'model': 'von-1.2'})
        self.assertEqual(h.evicted(), ['laya-typed-decisions', 'laya-multilingual'])
        self.assertEqual(h.loaded(), {'laya-english', 'von-1.2'})
        reasons = h.status()['evictions']
        self.assertTrue(all(e['reason'].startswith('memory: made room for von-1.2 at 16-bit') for e in reasons), reasons)
        self.assertEqual([e['residency'] for e in reasons], ['on_demand', 'on_demand'])
        # Only on-demand models go before manual ones: von-1.2 (on demand, newer) before laya-english (manual, older).
        h.ok('/load', {'model': 'laya-multilingual'})                          # 712 left, needs 1512 -> evict von-1.2
        self.assertEqual(h.loaded(), {'laya-english', 'laya-multilingual'})
        self.assertEqual(h.evicted()[-1], 'von-1.2')
        # Nothing on demand left that helps: the manual model goes.
        h.ok('/load', {'model': 'laya-multilingual', 'manual': True})
        h.ok('/load', {'model': 'von-1.2'})                                    # 1212 left; LRU manual is laya-english
        self.assertEqual(h.evicted()[-1], 'laya-english')
        self.assertEqual(h.status()['evictions'][-1]['residency'], 'manual')
        self.assertEqual(h.loaded(), {'laya-multilingual', 'von-1.2'})
        log = h.stop()
        self.assertEqual(log.count('"evicted":'), 4, log)

    def test_never_evicts_a_model_the_request_uses(self):
        h = self.helper(available_mb=2912)
        h.ok('/load', {'model': 'laya-english'})                               # on demand and least recently used
        h.ok('/load', {'model': 'laya-typed-decisions', 'manual': True})       # 1512 left
        h.set_available(2512)                                                   # something else took 400 MB: 1112 left
        # One request for English and Polish items: laya-english serves it, laya-multilingual must load (1512).
        # laya-english would go first (on demand, LRU) but is in flight; typed-decisions (manual) goes instead.
        r = h.judge(['plain English text', 'zażółć gęślą jaźń'])['results']
        self.assertEqual([x['model'] for x in r], ['laya-english', 'laya-multilingual'])
        self.assertEqual(h.evicted(), ['laya-typed-decisions'])
        self.assertEqual(h.loaded(), {'laya-english', 'laya-multilingual'})
        # Only the in-flight model could make room: refused, nothing unloaded.
        h.ok('/unload', {'model': 'laya-multilingual'})
        h.set_available(2000)                                                   # 1000 left with laya-english loaded
        code, reply = h.call('/judge', {'items': ['plain English', 'zażółć gęślą jaźń'], 'questions': Q})
        self.assertEqual(code, 507, reply)
        self.assertEqual(reply['error'], 'laya-multilingual at 16-bit needs ~1.5 GB; ~1.0 GB free without swapping. '
                                         'This request needs laya-english and laya-multilingual loaded together. '
                                         'Send one request per model, pick 8-bit, or allow swap in Verdict → Memory.')
        self.assertEqual(h.loaded(), {'laya-english'})

    def test_refusal_never_advises_unloading_a_model_the_request_needs(self):
        """Review 2 R2.5: following the advice (unload laya-english) and retrying must not be the suggested way out."""
        h = self.helper(available_mb=2000)
        h.ok('/load', {'model': 'laya-english'})
        h.ok('/load', {'model': 'laya-typed-decisions', 'manual': True})           # not needed by the request: 600 left
        body = {'items': ['plain English', 'zażółć gęślą jaźń'], 'questions': Q}
        code, reply = h.call('/judge', body)
        self.assertEqual(code, 507, reply)
        self.assertNotIn('Unload laya-english', reply['error'])
        self.assertNotIn('laya-english or', reply['error'])
        self.assertIn('This request needs laya-english and laya-multilingual loaded together.', reply['error'])
        self.assertIn('unload laya-typed-decisions', reply['error'])                # an idle model is still a way out
        self.assertEqual(h.loaded(), {'laya-english', 'laya-typed-decisions'})
        # A single-model refusal with nothing else loaded still reads as before.
        h.ok('/unload', {'model': 'laya-typed-decisions'}); h.ok('/unload', {'model': 'laya-english'})
        h.set_available(1000)
        code, reply = h.call('/judge', {'items': ['zażółć gęślą jaźń'], 'questions': Q})
        self.assertEqual((code, reply['error']), (507, 'laya-multilingual at 16-bit needs ~1.5 GB; ~1.0 GB free without swapping. '
                                                       'Pick 8-bit or allow swap in Verdict → Memory.'))

    def test_reload_under_negative_headroom_keeps_the_model(self):
        """Review 2 R2.2: the loaded model's credit is added to the raw (negative) headroom, not to a clamped zero."""
        h = self.helper(available_mb=3000)
        h.ok('/load', {'model': 'laya-english', 'bits': 16, 'manual': True})       # 1000 MB; 2000 left
        h.set_available(800)                                                     # raw headroom 800 − 1000 = −200
        self.assertEqual(h.status()['memory']['available_mb'], 0)
        # 4-bit needs 400 + 512 = 912; after unloading 16-bit only 800 would be free: refuse before unloading anything.
        code, reply = h.call('/load', {'model': 'laya-english', 'bits': 4, 'manual': True})
        self.assertEqual(code, 507, reply)
        self.assertTrue(reply['error'].startswith('laya-english at 4-bit needs ~0.9 GB; ~0.8 GB free without swapping.'), reply)
        status = h.status()
        self.assertEqual(set(status['models']), {'laya-english'})
        entry = status['models']['laya-english']
        self.assertEqual((entry['bits'], entry['residency']), (16, 'manual'))
        self.assertEqual(status['refused']['model'], 'laya-english')
        self.assertIsNone(status['error'])
        self.assertEqual(h.evicted(), [])
        self.assertEqual(h.judge(['x'], model='laya-english')['results'][0]['model'], 'laya-english')
        self.assertEqual(h.status()['models']['laya-english']['bits'], 16)       # served by the untouched model
        # With enough raw headroom the same reload fits: −50 + 1000 = 950 ≥ 912.
        h.set_available(950)
        h.ok('/load', {'model': 'laya-english', 'bits': 4, 'manual': True})
        self.assertEqual((h.status()['models']['laya-english']['bits'], h.residency('laya-english')), (4, 'manual'))

    def test_impossible_load_under_negative_headroom_evicts_nothing(self):
        """Review 2 re-verify: the eviction forecast starts from the raw deficit, not a clamped zero."""
        h = self.helper(available_mb=4000)
        for model in ('laya-english', 'laya-multilingual', 'laya-typed-decisions'): h.ok('/load', {'model': model})
        h.set_available(800)                                   # raw 800 − 2400 = −1600
        # von-1.2 needs 2012; even unloading all three frees 2400: −1600 + 2400 = 800 < 2012. Refuse, evict nothing.
        code, reply = h.call('/load', {'model': 'von-1.2'})
        self.assertEqual(code, 507, reply)
        self.assertEqual(h.loaded(), {'laya-english', 'laya-multilingual', 'laya-typed-decisions'})
        self.assertEqual(h.evicted(), [])
        # With the deficit paid off the same load evicts as usual: 2600 − 2400 = 200; +2400 ≥ 2012.
        h.set_available(2600)
        h.ok('/load', {'model': 'von-1.2'})
        self.assertIn('von-1.2', h.loaded()); self.assertTrue(h.evicted())

    def test_reload_that_fails_after_unloading_restores_the_model(self):
        h = self.helper(VERDICT_TEST_LOAD_FAULT='laya-english@8')
        h.ok('/load', {'model': 'laya-english', 'bits': 16, 'manual': True})
        code, reply = h.call('/load', {'model': 'laya-english', 'bits': 8})
        self.assertEqual((code, reply['error']), (400, 'test load fault'))
        status = h.status()
        entry = status['models']['laya-english']
        self.assertEqual((entry['bits'], entry['residency']), (16, 'manual'))
        self.assertEqual(status['error'], 'laya-english: test load fault')     # the failure stays visible
        h.ok('/unload', {'model': 'laya-english'}); h.ok('/load', {'model': 'laya-english'})
        self.assertEqual(h.status()['models']['laya-english']['bits'], 16)     # the failed 8 did not stick

    def test_refusal_unloads_nothing_and_reads_clearly(self):
        h = self.helper(available_mb=2000)
        h.ok('/load', {'model': 'laya-english', 'manual': True})              # 1000 left
        code, reply = h.call('/load', {'model': 'von-1.2'})                    # needs 2012; even without laya-english 2000
        self.assertEqual(code, 507)
        message = 'von-1.2 at 16-bit needs ~2.0 GB; ~1.0 GB free without swapping. Unload laya-english, pick 8-bit, or allow swap in Verdict → Memory.'
        self.assertEqual(reply['error'], message)
        self.assertEqual(h.loaded(), {'laya-english'})
        self.assertEqual(h.evicted(), [])
        status = h.status()
        self.assertEqual(status['refused']['message'], message)
        self.assertIsNone(status['error'])                                      # not a worker failure
        # The same text through a request's auto-load, the Python client and the CLI.
        code, reply = h.call('/judge', {'items': ['x'], 'questions': Q, 'model': 'von-1.2'})
        self.assertEqual((code, reply['error']), (507, message))
        env = dict(os.environ, PYTHONPATH=str(ROOT / 'client'))
        code = ("import sys, verdict\nfrom pathlib import Path\nverdict.SUPPORT = Path(sys.argv[1]); verdict.STATUS = verdict.SUPPORT / 'status.json'\n"
                "try: verdict.judge('x', {'x': verdict.Noul('Is it?')}, model='von-1.2', check=False)\n"
                "except verdict.VerdictError as e: print(e)\n")
        out = subprocess.run([sys.executable, '-c', code, str(h.dir)], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(out.stdout.strip(), message, out.stderr)
        # No loaded model and no lower precision: only the options that exist.
        h.ok('/unload', {'model': 'laya-english'})
        self.assertIsNone(h.status()['refused'])                                # an unload clears the notice
        h.set_available(500)
        code, reply = h.call('/load', {'model': 'von-1.2', 'bits': 4})          # unmeasured: disk-size fallback, 1.5 GB
        self.assertEqual(reply['error'], 'von-1.2 at 4-bit needs ~1.5 GB; ~0.5 GB free without swapping. Allow swap in Verdict → Memory.')
        # A refused precision switch keeps the loaded precision.
        h.set_available(1600)
        h.ok('/load', {'model': 'laya-english', 'bits': 8})                     # 600 + 512 fits
        code, reply = h.call('/load', {'model': 'laya-english', 'bits': 16})     # needs 1512; 1000 + 600 credit = 1600 fits
        self.assertEqual(code, 200, reply)
        h.set_available(1400)
        code, reply = h.call('/load', {'model': 'laya-english', 'bits': 8})      # needs 1112; 400 + 1000 credit fits
        self.assertEqual(code, 200, reply)
        h.set_available(900)
        code, reply = h.call('/load', {'model': 'laya-english', 'bits': 16})     # needs 1512; 300 + 600 credit does not
        self.assertEqual(code, 507)
        self.assertEqual(h.status()['models']['laya-english']['bits'], 8)
        code, reply = h.call('/load', {'model': 'laya-english'})                 # the refused 16 did not stick
        self.assertEqual(h.status()['models']['laya-english']['bits'], 8)

    def test_allow_swap_skips_the_check(self):
        h = self.helper(available_mb=1000)
        h.ok('/load', {'model': 'laya-typed-decisions'})                        # 400 + 512 fits: 600 left
        self.assertEqual(h.call('/load', {'model': 'von-1.2'})[0], 507)
        self.assertEqual(h.ok('/settings', {'allow_swap': True})['allow_swap'], True)
        h.ok('/load', {'model': 'von-1.2'})                                      # loads into swap, evicts nothing
        self.assertEqual(h.loaded(), {'laya-typed-decisions', 'von-1.2'})
        self.assertEqual(h.evicted(), [])
        self.assertTrue(h.status()['allow_swap'])
        h.ok('/settings', {'allow_swap': 'false'})                                # Automatic again
        h.ok('/unload', {'model': 'von-1.2'})
        self.assertEqual(h.call('/load', {'model': 'von-1.2'})[0], 507)
        self.assertEqual(h.evicted(), [])
        h2 = self.helper(available_mb=0, VERDICT_ALLOW_SWAP='1')                # the app's launch setting
        h2.ok('/load', {'model': 'laya-english'})
        self.assertTrue(h2.status()['allow_swap'])

    def test_idle_unload_per_class(self):
        # One Keep Hot minute = 0.2 s; idle check every 0.1 s.
        h = self.helper(VERDICT_TEST_MINUTE_SECONDS='0.2', VERDICT_TEST_IDLE_TICK_S='0.1', VERDICT_PRELOAD='laya-english')
        self.assertEqual((h.status()['manual_idle_minutes'], h.status()['on_demand_idle_minutes']), (0, 15))   # defaults
        h.ok('/settings', {'manual_idle_minutes': 30, 'on_demand_idle_minutes': 5})   # 6 s and 1 s here
        h.ok('/load', {'model': 'laya-multilingual'})
        h.ok('/load', {'model': 'von-1.2'})
        h.judge(['x'], model='laya-english')                                      # the manual clock starts now
        start = time.time()
        while time.time() - start < 1.6:                                          # keep von-1.2 busy: its own clock
            h.judge(['x'], model='von-1.2'); time.sleep(.1)
        loaded = h.loaded()
        self.assertNotIn('laya-multilingual', loaded)                              # on demand, idle > 1 s
        self.assertIn('von-1.2', loaded)                                           # on demand, used
        self.assertIn('laya-english', loaded)                                      # manual, idle < 6 s
        time.sleep(1.5)
        self.assertNotIn('von-1.2', h.loaded())
        self.assertIn('laya-english', h.loaded())
        time.sleep(3.3)                                                            # laya-english idle > 6 s
        self.assertEqual(h.loaded(), set())
        evictions = h.status()['evictions']
        self.assertEqual([e['model'] for e in evictions], ['laya-multilingual', 'von-1.2', 'laya-english'])
        self.assertEqual(evictions[0]['reason'], 'idle: unused for 5 min (loaded on demand)')
        self.assertEqual(evictions[2]['reason'], 'idle: unused for 30 min (manually loaded)')
        self.assertTrue(h.status()['idle_unloaded'])
        # Always (0) keeps both classes; a request reloads on demand.
        h.ok('/settings', {'manual_idle_minutes': 0, 'on_demand_idle_minutes': 0})
        h.judge(['x'], model='laya-english'); h.ok('/load', {'model': 'von-1.2', 'manual': True})
        time.sleep(1.5)
        self.assertEqual(h.loaded(), {'laya-english', 'von-1.2'})
        self.assertFalse(h.status()['idle_unloaded'])

    def test_settings_backward_compatible(self):
        h = self.helper()
        self.assertEqual(h.ok('/settings', {'idle_minutes': '7'}), {'idle_minutes': 7})   # older clients' reply
        s = h.status()
        self.assertEqual((s['idle_minutes'], s['manual_idle_minutes'], s['on_demand_idle_minutes']), (7, 7, 15))
        reply = h.ok('/settings', {'on_demand_idle_minutes': 30, 'manual_idle_minutes': 0})
        self.assertEqual(reply, {'idle_minutes': 0, 'manual_idle_minutes': 0, 'on_demand_idle_minutes': 30, 'allow_swap': False})
        for bad in ({'idle_minutes': 'soon'}, {'on_demand_idle_minutes': -5}, {'manual_idle_minutes': 5, 'allow_swap': 'perhaps'}):
            code, reply = h.call('/settings', bad)
            self.assertEqual(code, 400, bad)
        s = h.status()                                                               # a refused body changed nothing
        self.assertEqual((s['manual_idle_minutes'], s['on_demand_idle_minutes'], s['allow_swap']), (0, 30, False))
        self.assertEqual(h.ok('/settings', {}), {'idle_minutes': 0})
        # Older launchers set VERDICT_IDLE_MINUTES only: both classes (the bench and test harnesses rely on 0 = always).
        legacy = self.helper(VERDICT_IDLE_MINUTES='0').status()
        self.assertEqual((legacy['manual_idle_minutes'], legacy['on_demand_idle_minutes']), (0, 0))
        app = self.helper(VERDICT_IDLE_MINUTES='60', VERDICT_MANUAL_IDLE_MINUTES='60', VERDICT_ON_DEMAND_IDLE_MINUTES='5').status()
        self.assertEqual((app['idle_minutes'], app['manual_idle_minutes'], app['on_demand_idle_minutes']), (60, 60, 5))

    def test_von_11_context_is_2048(self):
        h = self.helper()
        catalog = {m['id']: m['context'] for m in h.status()['catalog']}
        self.assertEqual((catalog['von-1.1'], catalog['von-1.2'], catalog['laya-english']), (2048, 8192, 8192))
        r = h.ok('/judge', {'items': ['word ' * 1900, 'word ' * 2100], 'questions': Q, 'model': 'von-1.1'})['results']
        self.assertIn('noul', r[0]['answers']['x'])
        self.assertIn('von-1.1 accepts 2048', r[1]['error'])
        r = h.judge(['word ' * 2100], model='von-1.2')['results']                   # 1.2 keeps 8192
        self.assertIn('noul', r[0]['answers']['x'])
        h.judge(['x'], model='von-1.1')
        self.assertEqual(h.status()['models']['von-1.1']['context'], 2048)
        self.assertEqual(h.status()['models']['von-1.2']['context'], 8192)


class ProbeTests(unittest.TestCase):
    def test_real_probe_reports_available_memory(self):
        """Without the test hook: host_statistics64 pages and kern.memorystatus_level minus max(1 GB, 10% RAM)."""
        support = tempfile.mkdtemp(prefix='verdict-probe-'); self.addCleanup(shutil.rmtree, support, True)
        env = dict(os.environ, VERDICT_SUPPORT_DIR=support, VERDICT_STUB_MODELS='1', VERDICT_PORT='0', VERDICT_PRELOAD='',
                   HF_HUB_CACHE=support + '/hub', VERDICT_CATALOG=str(ROOT / 'Resources/models.json'))
        env.pop('VERDICT_TEST_MEMORY_FILE', None)
        proc = subprocess.Popen([str(BINARY)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            port = json.loads(proc.stdout.readline())['port']
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/status', timeout=5) as r:
                available = json.load(r)['memory']['available_mb']
            ram = int(subprocess.run(['sysctl', '-n', 'hw.memsize'], capture_output=True, text=True).stdout) / 1e6
            self.assertGreaterEqual(available, 0)
            self.assertLessEqual(available, ram - max(1000, ram * .1) + 1)
        finally:
            urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}/quit', data=b'{}', headers={'Content-Type': 'application/json'}), timeout=5).close()
            proc.wait(timeout=10); proc.stdout.close(); proc.stderr.close()

    def test_page_estimate_does_not_double_count(self):
        """Review 2 R2.1: purgeable pages can also be inactive and speculative pages are also file-backed. Free (not
        speculative) + file-backed + purgeable are disjoint; inactive anonymous pages are not counted as free.
        VERDICT_TEST_VM_STATS replaces the host_statistics64 counters and kern.memorystatus_level."""
        ram = int(subprocess.run(['sysctl', '-n', 'hw.memsize'], capture_output=True, text=True).stdout) / 1e6
        margin = max(1000, ram * .1)
        page = 16384
        pages = lambda mb: int(mb * 1e6 / page)
        free, speculative, external = pages(1000), pages(500), pages(1500)     # speculative ⊂ external (read-ahead)
        purgeable = pages(margin + 500)
        inactive = purgeable + pages(800)                                         # the purgeable pages + anonymous ones
        counters = {'page_size': page, 'free_count': free + speculative, 'speculative_count': speculative,
                    'inactive_count': inactive, 'purgeable_count': purgeable, 'external_page_count': external,
                    'memorystatus_level': 100}
        support = tempfile.mkdtemp(prefix='verdict-probe-'); self.addCleanup(shutil.rmtree, support, True)
        stats = Path(support) / 'vm.json'; stats.write_text(json.dumps(counters))
        env = dict(os.environ, VERDICT_SUPPORT_DIR=support, VERDICT_STUB_MODELS='1', VERDICT_PORT='0', VERDICT_PRELOAD='',
                   HF_HUB_CACHE=support + '/hub', VERDICT_CATALOG=str(ROOT / 'Resources/models.json'), VERDICT_TEST_VM_STATS=str(stats))
        env.pop('VERDICT_TEST_MEMORY_FILE', None)
        proc = subprocess.Popen([str(BINARY)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            port = json.loads(proc.stdout.readline())['port']
            def available():
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/status', timeout=5) as r:
                    return json.load(r)['memory']['available_mb']
            expected = (free + external + purgeable) * page / 1e6 - margin         # ≈ 3000 MB
            self.assertAlmostEqual(available(), expected, delta=1)
            # The kernel's pressure level still caps it.
            counters['memorystatus_level'] = 1; stats.write_text(json.dumps(counters))
            self.assertEqual(available(), max(0, round(ram * .01 - margin)))
        finally:
            urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}/quit', data=b'{}', headers={'Content-Type': 'application/json'}), timeout=5).close()
            proc.wait(timeout=10); proc.stdout.close(); proc.stderr.close()


if __name__ == '__main__': unittest.main()
