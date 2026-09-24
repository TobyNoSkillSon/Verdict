"""Compare native ordered rendering against Python's JSON oracle, including escaped transport."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

NATIVE = Path(__file__).resolve().parents[1]
FIXTURE = NATIVE / 'fixtures/dict-json-rendering.json'


class OrderedJSONTests(unittest.TestCase):
    def test_python_json_dumps(self):
        cases = json.loads(FIXTURE.read_text())['items']
        transport = [json.dumps({'item': json.loads(c['input_text'])}, ensure_ascii=True, separators=(',', ':')) for c in cases]
        # These two source keys decode to the same key and Python keeps its first slot,
        # replacing the value. The e-acute composed/decomposed keys remain distinct.
        duplicate = r'{"item":{"a":1,"\u0061":2,"e\u0301":3,"\u00e9":4}}'
        transport.append(duplicate)
        expected = [c['input_text'] for c in cases]
        expected.append(json.dumps(json.loads(duplicate)['item'], ensure_ascii=False))
        near_threshold = json.dumps({'item': {'fixed': -9574398254020816.0, 'tiny': 1e-5}}, ensure_ascii=True)
        transport.append(near_threshold)
        expected.append(json.dumps(json.loads(near_threshold)['item'], ensure_ascii=False))
        with tempfile.TemporaryDirectory() as directory:
            binary = str(Path(directory) / 'ordered-json-check')
            subprocess.run(['swiftc', str(NATIVE / 'Sources/VerdictHelper/OrderedJSON.swift'),
                            str(NATIVE / 'Tests/OrderedJSONCheck.swift'), '-o', binary], check=True, timeout=90)
            process = subprocess.run([binary], input='\n'.join(transport) + '\n', text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=30)
        rendered = process.stdout.splitlines()
        self.assertEqual(len(rendered), len(expected))
        for case, actual, want in zip([c['id'] for c in cases] + ['duplicate_looking', 'float_threshold'], rendered, expected):
            self.assertEqual(actual.encode('utf-8'), want.encode('utf-8'), case)


if __name__ == '__main__': unittest.main()
