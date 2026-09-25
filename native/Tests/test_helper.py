"""Native helper protocol smoke tests; isolated support directory, no model downloads.

native/scripts/build-helper.sh && python3 -m unittest discover -s native/Tests
"""
import json
import os
import socket
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


class HelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not BINARY.exists():
            raise RuntimeError(f'Build helper with xcodebuild first: {BINARY}')
        cls.tmp = tempfile.TemporaryDirectory()
        cls.support = Path(cls.tmp.name)
        env = dict(os.environ, VERDICT_SUPPORT_DIR=str(cls.support), VERDICT_STUB_MODELS='1',
                   VERDICT_PRELOAD='laya-english', VERDICT_PORT='0',
                   HF_HUB_CACHE=str(cls.support / 'hub'),
                   VERDICT_CATALOG=str(ROOT / 'Resources/models.json'))
        cls.proc = subprocess.Popen([str(BINARY)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        cls.port = json.loads(cls.proc.stdout.readline())['port']
        for _ in range(100):
            try:
                if 'laya-english' in json.loads((cls.support / 'status.json').read_text())['models']:
                    break
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(.05)
        else:
            raise AssertionError('preload did not finish')

    @classmethod
    def tearDownClass(cls):
        try: cls.call('POST', '/quit')
        finally:
            cls.proc.wait(timeout=5)
            cls.proc.stdout.close()
            cls.proc.stderr.close()
            cls.tmp.cleanup()

    @classmethod
    def call(cls, method, path, body=None):
        request = urllib.request.Request(f'http://127.0.0.1:{cls.port}{path}', method=method,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.load(response)

    def test_status_file_and_preload(self):
        self.call('POST', '/load', {'model': 'laya-english'})
        status = json.loads((self.support / 'status.json').read_text())
        self.assertEqual(status['port'], self.port)
        self.assertEqual(status['models']['laya-english']['device'], 'mlx')
        self.assertEqual(status['memory']['mlx_cache_mb'], 0)
        self.assertIn('catalog', self.call('GET', '/status'))

    def test_explicit_port_on_loopback(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            selected = listener.getsockname()[1]
        with tempfile.TemporaryDirectory() as isolated:
            env = dict(os.environ, VERDICT_SUPPORT_DIR=isolated, VERDICT_STUB_MODELS='1',
                       VERDICT_PORT=str(selected), VERDICT_PRELOAD='', HF_HUB_CACHE=isolated + '/hub',
                       VERDICT_CATALOG=str(ROOT / 'Resources/models.json'))
            child = subprocess.Popen([str(BINARY)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                line = child.stdout.readline()
                self.assertTrue(line, child.stderr.read() if child.poll() is not None else 'no port')
                self.assertEqual(json.loads(line)['port'], selected)
                with urllib.request.urlopen(f'http://127.0.0.1:{selected}/status', timeout=5) as response:
                    self.assertEqual(json.load(response)['port'], selected)
                with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{selected}/quit', data=b'{}', headers={'Content-Type': 'application/json'}), timeout=5): pass
                self.assertEqual(child.wait(timeout=5), 0)
            finally:
                if child.poll() is None: child.terminate(); child.wait(timeout=5)
                child.stdout.close(); child.stderr.close()

    def test_bundled_catalog_without_environment_override(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root) / 'Verdict.app/Contents'
            binary = app / 'MacOS/verdict-helper'
            binary.parent.mkdir(parents=True)
            shutil.copy2(BINARY, binary)
            resources = app / 'Resources'; resources.mkdir()
            models = json.loads((ROOT / 'Resources/models.json').read_text())
            models[0]['name'] = 'Bundled catalog sentinel'
            (resources / 'models.json').write_text(json.dumps(models))
            shutil.copy2(BINARY.parent / 'mlx.metallib', resources / 'mlx.metallib')
            env = dict(os.environ, VERDICT_SUPPORT_DIR=str(Path(root) / 'support'),
                       VERDICT_STUB_MODELS='1', VERDICT_PRELOAD='', HF_HUB_CACHE=str(Path(root) / 'hub'))
            env.pop('VERDICT_CATALOG', None)
            child = subprocess.Popen([str(binary)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                line = child.stdout.readline()
                self.assertTrue(line, child.stderr.read() if child.poll() is not None else 'no port')
                port = json.loads(line)['port']
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/status', timeout=5) as response:
                    self.assertEqual(json.load(response)['catalog'][0]['name'], 'Bundled catalog sentinel')
                with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}/quit', data=b'{}', headers={'Content-Type': 'application/json'}), timeout=5): pass
                self.assertEqual(child.wait(timeout=5), 0)
            finally:
                if child.poll() is None: child.terminate(); child.wait(timeout=5)
                child.stdout.close(); child.stderr.close()

    def test_judge_batches_and_counts(self):
        r = self.call('POST', '/judge', {'items': ['a', {'b': 1}], 'questions': {'x': {'type': 'noul', 'instructions': 'q'}}})
        self.assertEqual(len(r['results']), 2)
        self.assertEqual(r['results'][0]['answers']['x']['noul'], .75)
        self.assertGreaterEqual(self.call('GET', '/status')['items'], 2)

    def test_non_ascii_and_media_refusal(self):
        q = {'x': {'type': 'noul', 'instructions': 'q'}}
        r = self.call('POST', '/judge', {'items': ['zażółć gęślą jaźń', {'image': '/tmp/example.png'}], 'questions': q})
        self.assertEqual(r['results'][0]['model'], 'laya-multilingual')
        unsupported = {'error': 'Verdict judges text; image, audio and video items are not supported.', 'model': None, 'ms': 0}
        self.assertEqual(r['results'][1], unsupported)
        for key in ('image', 'images', 'audio', 'video', 'videos'):
            explicit = self.call('POST', '/judge', {'items': [{key: '/tmp/unused'}], 'questions': q, 'model': 'laya-english'})
            self.assertEqual(explicit['results'][0], unsupported)

    def test_bad_requests(self):
        for path, body in [('/judge', {'items': [], 'questions': {}}), ('/load', {'model': 'nope'})]:
            with self.assertRaises(urllib.error.HTTPError) as cm: self.call('POST', path, body)
            self.assertEqual(cm.exception.code, 400)
            self.assertIn('error', json.load(cm.exception))
            cm.exception.close()

    def test_context_refusal(self):
        r = self.call('POST', '/judge', {'items': ['short', ' '.join(['word'] * 9000)],
                                           'questions': {'x': {'type': 'noul', 'instructions': 'q'}}})
        self.assertEqual(r['results'][0]['answers']['x']['noul'], .75)
        self.assertIn('8192', r['results'][1]['error'])

    def test_media_only_does_not_load_a_model(self):
        self.call('POST', '/unload', {'model': 'laya-english'})
        r = self.call('POST', '/judge', {'items': [{'audio': 'ignored.wav'}],
                                       'questions': {'x': {'type': 'noul', 'instructions': 'q'}}})
        self.assertIsNone(r['results'][0]['model'])
        self.assertEqual(self.call('GET', '/status')['models'].get('laya-english'), None)

    def test_choice_criteria_order(self):
        r = self.call('POST', '/judge', {'items': [{'z': 1, 'a': 'żółć'}], 'questions': {
            'choice': {'type': 'choice', 'instructions': 'pick', 'criteria': {'z-last': 'first', 'a-first': 'second'}}}})
        self.assertEqual(r['results'][0]['answers']['choice']['choice'], 'z-last')

    def test_canonically_equivalent_labels_stay_distinct(self):
        """Review #1: "é" and "e\u0301" are two JSON keys; the answer keeps both (the stub trapped on them)."""
        labels = {'\u00e9': 'first', 'e\u0301': 'second'}
        r = self.call('POST', '/judge', {'items': ['x'], 'model': 'laya-english', 'questions': {
            'c': {'type': 'choice', 'instructions': 'pick', 'criteria': labels}}})
        self.assertEqual(sorted(r['results'][0]['answers']['c']['probabilities']), sorted(labels))
        self.assertIsNone(self.proc.poll())

    def test_question_ids_are_bytes(self):
        """Ids differing only by NFC/NFD are two JSON keys: both answered, in the helper and through the client."""
        questions = {'\u00e9': {'type': 'noul', 'instructions': 'first'}, 'e\u0301': {'type': 'choice', 'instructions': 'second',
                                                                                     'criteria': {'a': None, 'b': 'bee'}}}
        r = self.call('POST', '/judge', {'items': ['x', 'y'], 'model': 'laya-english', 'questions': questions})
        for result in r['results']:
            self.assertEqual(sorted(result['answers']), sorted(questions))
            self.assertIn('noul', result['answers']['\u00e9']); self.assertIn('choice', result['answers']['e\u0301'])
        sys.path.insert(0, str(ROOT / 'client'))
        import verdict
        old = verdict.SUPPORT, verdict.STATUS
        try:
            verdict.SUPPORT, verdict.STATUS = self.support, self.support / 'status.json'
            result = verdict.judge('x', questions, model='laya-english', check=False)
            self.assertEqual(sorted(result.answers), sorted(questions))
            self.assertEqual(result['\u00e9'].noul, .75); self.assertEqual(result['e\u0301'].choice, 'a')
        finally:
            verdict.SUPPORT, verdict.STATUS = old

    def test_shed_unload_settings_trim(self):
        self.call('POST', '/unload', {'model': 'laya-multilingual'})
        self.call('POST', '/unload', {'model': 'laya-english'})
        self.call('POST', '/load', {'model': 'laya-english'})
        self.call('POST', '/load', {'model': 'laya-multilingual', 'bits': '8'})
        self.assertEqual(self.call('GET', '/status')['models']['laya-multilingual']['bits'], 8)
        self.assertEqual(self.call('POST', '/shed')['loaded'], ['laya-english'])
        self.assertEqual(self.call('POST', '/settings', {'idle_minutes': '2'})['idle_minutes'], 2)
        self.assertTrue(self.call('POST', '/trim')['ok'])
        self.assertEqual(self.call('POST', '/unload', {'model': 'laya-english'})['loaded'], [])

    def test_cache_layout_and_delete(self):
        # Use the actual repository cache path from models.json, not the model id.
        root = self.support / 'hub/models--aac6fef--laya-mlx'
        blob = root / 'blobs/fixture'; blob.parent.mkdir(parents=True, exist_ok=True)
        blob.write_bytes(b'weights')
        snapshot = root / 'snapshots/fixture-sha'; snapshot.mkdir(parents=True)
        (snapshot / 'model.safetensors').symlink_to(blob)
        (root / 'refs').mkdir(); (root / 'refs/main').write_text('fixture-sha')
        self.assertEqual(self.call('GET', '/status')['installed']['laya-english']['bytes'], 7)
        result = self.call('POST', '/delete', {'model': 'laya-english'})
        self.assertNotIn('laya-english', result['installed'])
        self.assertFalse(blob.exists())

    def test_client_unchanged(self):
        sys.path.insert(0, str(ROOT / 'client'))
        import verdict
        old = verdict.SUPPORT, verdict.STATUS
        try:
            verdict.SUPPORT, verdict.STATUS = self.support, self.support / 'status.json'
            r = verdict._call('POST', '/judge', {'items': ['hello'], 'questions': {'x': {'type': 'noul', 'instructions': 'q'}}})
            self.assertEqual(r['results'][0]['answers']['x']['noul'], .75)
            verdict._call('POST', '/unload', {'model': 'laya-multilingual'})    # bodyful control call
            self.assertIn('models', verdict._call('GET', '/status'))
        finally:
            verdict.SUPPORT, verdict.STATUS = old

    def raw(self, method, path, body=None, **headers):
        import http.client
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=10)
        try:
            conn.request(method, path, body=body, headers={k.replace('_', '-'): v for k, v in headers.items()})
            reply = conn.getresponse()
            return reply.status, json.loads(reply.read() or b'{}')
        finally:
            conn.close()

    def test_loopback_origin_boundary(self):
        """Review #7: Origin, foreign Host (DNS rebinding) and non-JSON POSTs are refused before any state change."""
        before = self.call('GET', '/status')['idle_minutes']
        body = json.dumps({'idle_minutes': before + 23})
        local, json_type = f'127.0.0.1:{self.port}', 'application/json'
        refused = [
            dict(Host=local, Content_Type=json_type, Origin='https://untrusted.example'),
            dict(Host=local, Content_Type=json_type, Origin='null'),
            dict(Host='untrusted.example', Content_Type=json_type),
            dict(Host=f'untrusted.example:{self.port}', Content_Type=json_type),
            dict(Host=f'127.0.0.1:{self.port + 1}', Content_Type=json_type),
            dict(Host=local, Content_Type='text/plain'),
            dict(Host=local, Content_Type='application/x-www-form-urlencoded'),
            dict(Host=local),
        ]
        for headers in refused:
            status, reply = self.raw('POST', '/settings', body, **headers)
            self.assertIn(status, (403, 415), headers)
            self.assertIn('error', reply)
        status, _ = self.raw('GET', '/status', Host=local, Origin='https://untrusted.example')
        self.assertEqual(status, 403)
        status, _ = self.raw('GET', '/status', Host='rebound.example')
        self.assertEqual(status, 403)
        self.assertEqual(self.call('GET', '/status')['idle_minutes'], before)
        # Local clients: 127.0.0.1 or localhost with the port, JSON (with or without charset).
        for host, ctype in [(local, 'application/json; charset=utf-8'), (f'localhost:{self.port}', json_type), (f'LOCALHOST:{self.port}', json_type)]:
            status, reply = self.raw('POST', '/settings', json.dumps({'idle_minutes': before}), Host=host, Content_Type=ctype)
            self.assertEqual((status, reply), (200, {'idle_minutes': before}))
        status, reply = self.raw('POST', '/trim', None, Host=local, Content_Type=json_type)    # bodiless control
        self.assertEqual(status, 200)
        # The benchmark driver's HTTP runtime.
        sys.path.insert(0, str(ROOT / 'bench'))
        import runtimes
        rt = object.__new__(runtimes.HttpRuntime); rt.port, rt.key = self.port, 'helper@swift'
        self.assertIn('models', rt.call('/status'))
        self.assertEqual(rt.call('/settings', {'idle_minutes': before}), {'idle_minutes': before})

    def test_invalid_precision_keeps_model(self):
        """Review #8: a refused precision neither unloads the working model nor sticks for later loads."""
        for model, bad in [('laya-english', 32), ('laya-english', 7), ('von-1.2', 7)]:
            self.call('POST', '/load', {'model': model})
            with self.assertRaises(urllib.error.HTTPError) as cm:
                self.call('POST', '/load', {'model': model, 'bits': bad})
            self.assertEqual(cm.exception.code, 400)
            self.assertIn('precision must be', json.load(cm.exception)['error']); cm.exception.close()
            self.assertIn(model, self.call('GET', '/status')['models'], f'{model} unloaded by bits={bad}')
            self.call('POST', '/unload', {'model': model})
            self.call('POST', '/load', {'model': model})
            self.assertEqual(self.call('GET', '/status')['models'][model]['bits'], 0)
            self.call('POST', '/unload', {'model': model})
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.call('POST', '/load', {'model': 'nope', 'bits': 8})
        self.assertEqual(cm.exception.code, 400); cm.exception.close()


if __name__ == '__main__': unittest.main()
