"""The installers' readiness check: helper answering and not loading, and a model loaded unless the launch set is
empty. A fresh install has no launch set (no config.json yet, or hotModels []), so it is ready with nothing loaded.

python3 -m unittest -v Tests.test_install
"""
import json
import re
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALLERS = [ROOT / 'scripts/install.sh', ROOT / 'native/scripts/install-release.sh']


def readiness_script(installer):
    text = installer.read_text()
    match = re.search(r"ready_check\(\) \{.*?<<'PYEOF'[^\n]*\n(.*?)\nPYEOF", text, re.S)
    assert match, installer
    return match.group(1)


class Helper(BaseHTTPRequestHandler):
    reply = {}
    def do_GET(self):
        body = json.dumps(Helper.reply).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args): pass


class ReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(('127.0.0.1', 0), Helper)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close()

    def ready(self, installer, status, config=None, status_file=True):
        Helper.reply = status
        with tempfile.TemporaryDirectory() as support:
            if status_file:
                Path(support, 'status.json').write_text(json.dumps({'port': self.server.server_port}))
            if config is not None:
                Path(support, 'config.json').write_text(json.dumps(config))
            p = subprocess.run(['python3', '-', support], input=readiness_script(installer), text=True, capture_output=True, timeout=30)
            return p.returncode == 0

    def test_fresh_install_is_ready_with_nothing_loaded(self):
        for installer in INSTALLERS:
            with self.subTest(installer.name):
                self.assertTrue(self.ready(installer, {'models': {}}))                                   # no config.json yet
                self.assertTrue(self.ready(installer, {'models': {}}, {'executable': '/x', 'hotModels': []}))
                self.assertTrue(self.ready(installer, {'models': {}}, {'executable': '/x'}))             # no launch set recorded

    def test_existing_launch_set_waits_for_a_model(self):
        for installer in INSTALLERS:
            with self.subTest(installer.name):
                config = {'executable': '/x', 'hotModels': ['laya-english']}
                self.assertFalse(self.ready(installer, {'models': {}}, config))
                self.assertFalse(self.ready(installer, {'models': {}, 'loading': 'laya-english'}, config))
                self.assertTrue(self.ready(installer, {'models': {'laya-english': {}}}, config))

    def test_not_ready_while_loading_or_before_the_helper_answers(self):
        for installer in INSTALLERS:
            with self.subTest(installer.name):
                self.assertFalse(self.ready(installer, {'models': {}, 'loading': 'laya-english'}))
                self.assertFalse(self.ready(installer, {'models': {}}, status_file=False))

    def test_no_predefined_model(self):
        for installer in INSTALLERS:
            self.assertNotIn("'laya-english'", readiness_script(installer))
            self.assertNotIn('first run downloads', installer.read_text())


if __name__ == '__main__': unittest.main()
