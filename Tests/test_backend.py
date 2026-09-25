"""The app's Backend against a stub helper: Delete owns the launch set (Review 2 R2.3).

Compiles the real Sources/Verdict/Backend.swift and VerdictCore with Tests/BackendProbe/delete_probe.swift in a temporary
directory, with a temporary support directory; no app or helper is started.

python3 -m unittest Tests.test_backend
"""
import http.server
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class Stub(http.server.BaseHTTPRequestHandler):
    """Holds /delete until the probe creates support/release (the request is queued), then answers."""
    support: Path
    succeed: bool

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])) or b'{}')
        deadline = time.time() + 20
        while not (self.support / 'release').exists() and time.time() < deadline:
            time.sleep(.02)
        if self.path == '/delete' and self.succeed:
            status = json.loads((self.support / 'status.json').read_text())
            status['models'] = {}
            tmp = self.support / 'status.tmp'; tmp.write_text(json.dumps(status)); tmp.replace(self.support / 'status.json')
            code, reply = 200, {'installed': {}}
        else:
            code, reply = 400, {'error': f"{body.get('model')}: delete failed"}
        data = json.dumps(reply).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def log_message(self, *args): pass


class DeleteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='verdict-backend-probe-')
        t = cls.build.name
        run = lambda args: subprocess.run(args, check=True, timeout=300, capture_output=True)
        run(['xcrun', 'swiftc', '-emit-library', '-emit-module', '-module-name', 'VerdictCore', str(ROOT / 'Sources/VerdictCore/Core.swift'),
             '-o', f'{t}/libVerdictCore.dylib', '-emit-module-path', f'{t}/VerdictCore.swiftmodule'])
        run(['xcrun', 'swiftc', '-parse-as-library', '-I', t, '-L', t, '-lVerdictCore', str(ROOT / 'Sources/Verdict/Backend.swift'),
             str(ROOT / 'Tests/BackendProbe/delete_probe.swift'), '-o', f'{t}/probe'])

    @classmethod
    def tearDownClass(cls): cls.build.cleanup()

    def probe(self, succeed, model='laya-english'):
        support = Path(tempfile.mkdtemp(prefix='verdict-backend-support-'))
        handler = type('Handler', (Stub,), {'support': support, 'succeed': succeed})
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            env = dict(os.environ, DYLD_LIBRARY_PATH=self.build.name, VERDICT_SUPPORT_DIR=str(support), PROBE_PORT=str(server.server_port))
            out = subprocess.run([f'{self.build.name}/probe', 'ok' if succeed else 'fail', model], env=env,
                                 capture_output=True, text=True, timeout=60)
            self.assertEqual(out.returncode, 0, out.stderr)
            return json.loads(out.stdout.strip().splitlines()[-1])
        finally:
            server.shutdown(); server.server_close()
            subprocess.run(['rm', '-rf', str(support)])

    def test_successful_delete_leaves_the_launch_set(self):
        seen = self.probe(succeed=True)
        self.assertEqual(seen['while_queued'], ['laya-english'])    # unchanged until the helper confirms
        self.assertEqual(seen['after'], [])                          # and gone for good afterwards
        self.assertIsNone(seen['error']); self.assertIsNone(seen['busy'])

    def test_failed_delete_keeps_the_launch_set(self):
        seen = self.probe(succeed=False, model='laya-multilingual')
        self.assertEqual(seen['while_queued'], ['laya-multilingual'])
        self.assertEqual(seen['after'], ['laya-multilingual'])
        self.assertEqual(seen['error'], 'laya-multilingual: delete failed')


if __name__ == '__main__': unittest.main()
