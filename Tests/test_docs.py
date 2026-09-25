"""Release-facing text must match the catalog and the helper's behaviour (review #10).

python3 -m unittest -v Tests.test_docs
"""
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def number(text):
    return float(re.match(r'[0-9][0-9,]*(?:\.[0-9]+)?', text).group().replace(',', ''))


class DocsTests(unittest.TestCase):
    def test_readme_models_table_matches_benchmarks(self):
        bench = json.loads((ROOT / 'Resources/benchmarks.json').read_text())
        catalog = json.loads((ROOT / 'Resources/models.json').read_text())
        names = {m['name']: m['id'] for m in catalog}
        # The README table documents each model at its native precision (Laya 16, Von 32); benchmarks.json
        # default_bits is the recommended precision, which can differ.
        native = {m['id']: 32 if m.get('runtime') == 'von' else 16 for m in catalog}
        readme = (ROOT / 'README.md').read_text()
        rows = [r for r in readme.splitlines() if r.startswith('| ') and r.strip('|* ').split(' |')[0].strip('* ') in names]
        seen = set()
        for row in rows:
            cells = [c.strip() for c in row.strip('|').split('|')]
            model = names[cells[0].strip('* ')]
            if model not in bench:
                continue
            seen.add(model)
            entry = bench[model]
            bits = native[model]
            r = entry['precisions'][str(bits)]
            self.assertEqual(int(cells[4]), bits, model)
            self.assertAlmostEqual(number(cells[5]) / 100, r['accuracy'], delta=0.0005, msg=model)
            self.assertAlmostEqual(number(cells[6]), r['ece'], delta=0.0005, msg=model)
            self.assertAlmostEqual(number(cells[7]), r['ms'], delta=0.05, msg=model)
            self.assertAlmostEqual(number(cells[8]), r['items_per_s'], delta=0.5, msg=model)
            self.assertAlmostEqual(number(cells[9]), r['j_per_1k'], delta=0.5, msg=model)
            self.assertAlmostEqual(number(cells[10]) * 1000, r['memory_mb'], delta=5, msg=model)
        self.assertEqual(seen, {m for m in bench if m != 'jev'})

    def test_no_stale_behaviour_claims(self):
        readme = (ROOT / 'README.md').read_text()
        self.assertNotIn('reloads it in place', readme)             # selection no longer reloads; Reload does
        self.assertNotIn('`n = 500`', readme)                       # old two-task benchmark
        menu = (ROOT / 'Sources/Verdict/ModelsMenu.swift').read_text()
        self.assertNotIn('cut from the end', menu)                  # over-context items get an error
        registry = (ROOT / 'native/Sources/VerdictHelper/Registry.swift').read_text()
        self.assertNotIn('Python worker remains the production', registry)


if __name__ == '__main__':
    unittest.main()
