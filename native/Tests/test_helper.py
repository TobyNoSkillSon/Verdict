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
                with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{selected}/quit', data=b'{}'), timeout=5): pass
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
                with urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}/quit', data=b'{}'), timeout=5): pass
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
        finally:
            verdict.SUPPORT, verdict.STATUS = old


if __name__ == '__main__': unittest.main()
