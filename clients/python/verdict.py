#!/usr/bin/env python3
"""verdict: judge many items with the same typed questions, locally, in milliseconds.

    from verdict import judge, Choice, Score, Noul

    r = judge(ticket, {
        "dept":    Choice("Which team should handle this?", billing="charges, refunds", tech="bugs, outages", other="none of these"),
        "refund":  Noul("Does the customer ask for money back?"),
        "urgency": Score("How urgent is this?", ["routine", "this week", "blocking today"]),
    })
    if r.dept == "billing" and r.refund > 0.7:      # answers compare like values
        route_to_billing(ticket)
    r.dept.probabilities, r.dept.confidence          # detail one attribute away

    for r in judge(tickets, questions): ...          # a list in, a list of results out, order kept
    verdict = gate(state, {"safe": Noul("...")}, allow_if=lambda a: a.safe > 0.9)

Question shapes follow the TypeSafe/Laya convention (same names, same fields), so
questions written for Jev work here unchanged. Plain dicts are still accepted.

CLI (JSONL in, JSONL out):
    verdict judge --questions q.json [--field KEY] [--sort NAME] [--min X] [--top N] [--model ID] [--json] < items.jsonl
        default output, one line per item:  #index  name=value(conf) …  | first 60 chars of the item
    verdict skill [--install DIR]      print the agent skill (named triage), or write DIR/triage/SKILL.md
    verdict status | verdict models [--all] [--json] | verdict info MODEL [--json] | verdict load ID [--manual] | verdict unload ID | verdict quit
        load: on demand (Keep Hot "Loaded on demand"); --manual loads like the menu (launch set, "Manually loaded")

Python: models() returns the catalog with state, measured benchmarks and Hugging Face/GitHub links.

Talks to the Verdict worker on loopback; starts the Verdict app if it is not running.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import warnings
from pathlib import Path

SUPPORT = Path(os.environ.get('VERDICT_SUPPORT_DIR') or Path.home() / 'Library/Application Support/Verdict')
STATUS = SUPPORT / 'status.json'
APP = Path(os.environ.get('VERDICT_APP') or '/Applications/Verdict.app')


class VerdictError(RuntimeError):
    pass


# --------------------------------------------------------------------------- questions

class Question(dict):
    """A typed question; a dict, so it serializes and prints as the wire format."""
    type = ''

    def __init__(self, instructions, criteria=None):
        super().__init__(type=self.type, instructions=instructions)
        if criteria is not None:
            self['criteria'] = criteria


class Choice(Question):
    """One of several named options. `Choice(q, a="desc", b="desc")` or `Choice(q, {"a": "desc"})` or `Choice(q, ["a", "b"])`."""
    type = 'choice'

    def __init__(self, instructions, criteria=None, **options):
        if options:
            criteria = dict(criteria or {}, **options)
        if isinstance(criteria, (list, tuple)):
            criteria = {c: c for c in criteria}
        super().__init__(instructions, criteria or {})


class Score(Question):
    """An ordered rubric; the answer is the expected level 0…n-1."""
    type = 'score'

    def __init__(self, instructions, levels):
        super().__init__(instructions, list(levels))


class Noul(Question):
    """A yes/no proposition; the answer is P(true)."""
    type = 'noul'


yesno, choice, score = Noul, Choice, Score

ESCAPE_WORDS = ('other', 'none', 'unclear', 'unknown', 'neither', 'n/a', 'not applicable', 'something else')
COUNT_WORDS = re.compile(r'\b(how many|count|number of|total|sum|date|what year|when did)\b', re.I)
BARE_LEVELS = {'low', 'medium', 'high', 'small', 'large', 'weak', 'strong', 'bad', 'good', 'ok', 'poor'}


def lint(questions):
    """Warn about question shapes the field has learned to avoid. Never raises."""
    for name, q in questions.items():
        t, ins = q.get('type'), q.get('instructions', '')
        if COUNT_WORDS.search(ins):
            warnings.warn(f'{name}: the model does not count or do dates well — ask one yes/no per item and sum in code', stacklevel=3)
        if re.search(r'\b(and|or)\b', ins) and t == 'noul':
            warnings.warn(f'{name}: "and/or" in a yes/no question mixes judgements — split it into two questions', stacklevel=3)
        if t == 'choice':
            labels = [l.lower() for l in q.get('criteria', {})]
            if len(labels) > 20:
                warnings.warn(f'{name}: {len(labels)} options; accuracy drops past ~20 — use a two-stage choice', stacklevel=3)
            if not any(any(w in l for w in ESCAPE_WORDS) for l in labels):
                warnings.warn(f'{name}: no escape option (other / unclear / none) — the model is forced to pick one of {labels}', stacklevel=3)
        if t == 'score':
            levels = [str(l).lower().strip() for l in q.get('criteria', [])]
            if all(l in BARE_LEVELS for l in levels):
                warnings.warn(f'{name}: score levels are bare degrees ({levels}); describe each as a checkable situation', stacklevel=3)


# --------------------------------------------------------------------------- answers

class Answer:
    """Common surface: .confidence, .probabilities, .raw. Subclasses compare like their value."""
    @property
    def confidence(self): return self.raw.get('confidence')
    @property
    def probabilities(self): return self.raw.get('probabilities')
    @property
    def calibrated(self): return self.raw.get('calibrated', True)


class ChoiceAnswer(str, Answer):
    def __new__(cls, raw):
        o = str.__new__(cls, raw.get('choice', '')); o.raw = raw; return o
    @property
    def choice(self): return str(self)
    def __repr__(self): return f'Choice({str(self)!r}, confidence={self.confidence})'


class NoulAnswer(float, Answer):
    def __new__(cls, raw):
        o = float.__new__(cls, raw.get('noul', 0.0)); o.raw = raw; return o
    @property
    def noul(self): return float(self)
    def __bool__(self): return float(self) > 0.5
    def __repr__(self): return f'Noul({float(self):.3f})'


class ScoreAnswer(float, Answer):
    def __new__(cls, raw):
        o = float.__new__(cls, raw.get('score', 0.0)); o.raw = raw; return o
    @property
    def score(self): return float(self)
    def __repr__(self): return f'Score({float(self):.2f}, confidence={self.confidence})'


def _wrap(raw):
    if 'choice' in raw: return ChoiceAnswer(raw)
    if 'noul' in raw: return NoulAnswer(raw)
    return ScoreAnswer(raw)


class Result:
    """Answers for one item. `r.name`, `r["name"]`, `r.answers`, `r.error`, `r.model`, `r.ms`, `r.raw`."""
    def __init__(self, raw):
        self.raw = raw
        self.error = raw.get('error')
        self.model = raw.get('model')
        self.ms = raw.get('ms')
        self.answers = {k: _wrap(v) for k, v in raw.get('answers', {}).items()}

    def __getattr__(self, name):
        answers = self.__dict__.get('answers', {})
        if name in answers: return answers[name]
        raise AttributeError(name)

    def __getitem__(self, key):
        if key in self.answers: return self.answers[key]
        return self.raw[key]              # 'answers', 'model', 'ms', 'error' for dict-style callers

    def __contains__(self, key): return key in self.answers or key in self.raw
    def get(self, key, default=None): return self.raw.get(key, default)
    def __bool__(self): return self.error is None
    def __repr__(self):
        if self.error: return f'Result(error={self.error!r})'
        return 'Result(' + ', '.join(f'{k}={v!r}' for k, v in self.answers.items()) + ')'


# --------------------------------------------------------------------------- transport

def _port():
    try:
        s = json.loads(STATUS.read_text())
    except (OSError, ValueError):
        return None
    port, pid = s.get('port'), s.get('pid')
    if not port or not pid:
        return None
    try:
        os.kill(pid, 0)
    except OSError:
        return None
    return port


def _call(method, path, body=None, timeout=600):
    port = _port()
    if port is None:
        raise VerdictError('Verdict worker is not running')
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read()).get('error')
        except Exception:
            msg = str(e)
        raise VerdictError(msg) from None


def ensure_running(wait=90):
    """Return the worker port, launching the Verdict app if needed."""
    port = _port()
    if port:
        return port
    if APP.exists():
        subprocess.run(['open', '-g', str(APP)], check=False)
    else:
        raise VerdictError(f'Verdict is not running and {APP} is not installed')
    deadline = time.time() + wait
    while time.time() < deadline:
        port = _port()
        if port:
            return port
        time.sleep(0.5)
    raise VerdictError('Verdict did not start in time')


def status():
    ensure_running()
    return _call('GET', '/status')


def _benchmarks():
    for p in ([Path(os.environ['VERDICT_BENCHMARKS'])] if os.environ.get('VERDICT_BENCHMARKS') else []) + [
            APP / 'Contents/Resources/benchmarks.json', Path(__file__).resolve().parents[1] / 'Resources/benchmarks.json']:
        try:
            return json.loads(p.read_text())
        except (OSError, ValueError):
            continue
    return {}


def _selected_precision():
    """config.precision: model id -> bits, 0 = the model's native precision."""
    try:
        return json.loads((SUPPORT / 'config.json').read_text()).get('precision') or {}
    except (OSError, ValueError, AttributeError):
        return {}


def native_bits(runtime):
    """Native weight precision: Laya checkpoints are fp16, Von fp32."""
    return 32 if runtime == 'von' else 16


def precision_options(runtime):
    return [32, 16, 8, 4] if runtime == 'von' else [16, 8, 4]


def _precisions(entry, native):
    """benchmarks.json entry -> (default_bits, {bits: result}). The older flat shape is one result at the default."""
    if not isinstance(entry, dict):
        return native, {}
    default = entry.get('default_bits') or native
    if 'precisions' in entry:
        out = {}
        for k, v in (entry.get('precisions') or {}).items():
            try:
                if isinstance(v, dict): out[int(k)] = v
            except ValueError:
                pass
        return default, out
    return default, {entry.get('default_bits') or 16: entry}


def engine_label(loaded, chip=None):
    """The app's engine label for a loaded model (/status models[id]): 'Optimized · <chip>' on Verdict's optimized
    path (fast tokenizer + windowed attention, self-tested at load), else 'MLX' (not fully optimized: the stock path, or only one of the two active; engine_reason says why).
    Mirrors VerdictCore.engineLabel."""
    engine = loaded.get('engine')
    if engine is None:   # helpers before the engine field
        o = loaded.get('optimizations') or {}
        engine = 'optimized' if o.get('tokenizer') == 'fast' and o.get('attention') == 'windowed' else 'mlx'
    if engine != 'optimized':
        return 'MLX'
    return f'Optimized \u00b7 {chip}' if chip else 'Optimized'


def _eff(bits, native):
    return native if not bits else int(bits)


RECOMMENDATION_MARGIN = 0.005   # 0.5 accuracy points below the native precision


def recommended_bits(results, native, options=None):
    """The recommended precision (mirrors VerdictCore.recommendedBits): among measured precisions (accuracy present)
    with accuracy >= the NATIVE precision's accuracy - 0.5 points, the lowest J/1k; ties -> lower ms; then higher bits.
    A precision without energy (or ms) ranks after those with it. results: {bits: result}; None when the native
    precision has no measured accuracy. The benchmark tooling writes default_bits with this function."""
    results = {int(b): r for b, r in (results or {}).items() if isinstance(r, dict)}
    reference = (results.get(int(native)) or {}).get('accuracy')
    if reference is None:
        return None
    inf = float('inf')
    candidates = [(b, r) for b, r in results.items()
                  if r.get('accuracy') is not None and (options is None or b in options)
                  and r['accuracy'] >= reference - RECOMMENDATION_MARGIN - 1e-9]
    key = lambda c: (inf if c[1].get('j_per_1k') is None else c[1]['j_per_1k'],
                     inf if c[1].get('ms') is None else c[1]['ms'], -c[0])
    return min(candidates, key=key)[0] if candidates else None


_MINUS = '\u2212'


def _signed(x, fmt):
    return (_MINUS if x < 0 else '+') + format(abs(x), fmt)


def deltas(result, base):
    """Figures at one precision vs the recommended (default) precision, as short strings (None when either side is unmeasured).

    {"accuracy": "−0.4 pt", "ece": "+0.012", "speed": "35% faster", "energy": "20% less energy"}; speed is a rate change;
    from 2x on speed reads "2.0× slower" and extra energy "2.9× more energy"."""
    result, base, out = result or {}, base or {}, {}
    a, b = result.get('accuracy'), base.get('accuracy')
    if a is not None and b is not None:
        d = (a - b) * 100
        out['accuracy'] = '\u00b10.0 pt' if abs(d) < 0.05 else _signed(d, '.1f') + ' pt'
    a, b = result.get('ece'), base.get('ece')
    if a is not None and b is not None:
        d = a - b
        out['ece'] = '\u00b10.000' if abs(d) < 0.0005 else _signed(d, '.3f')
    a, b = result.get('ms'), base.get('ms')
    if a and b:
        ratio = b / a if a < b else a / b
        word = 'faster' if a < b else 'slower'
        amount = f'{ratio:.1f}\u00d7' if ratio >= 2 else f'{(ratio - 1) * 100:.0f}%'
        out['speed'] = 'same speed' if ratio - 1 < 0.01 or amount == '0%' else f'{amount} {word}'
    a, b = result.get('j_per_1k'), base.get('j_per_1k')
    if a is not None and b:
        c = a / b - 1
        out['energy'] = ('same energy' if abs(c) < 0.005 else f'{a / b:.1f}\u00d7 more energy' if c >= 1
                         else f"{abs(c) * 100:.0f}% {'less' if c < 0 else 'more'} energy")
    return out


def models():
    """Every catalog model with its state, measured benchmarks and links, for choosing one.

    [{"id", "name", "family", "inputs", "params", "context", "languages", "license",
      "state": "hot"|"downloaded"|"available"|"hosted", "loadable": bool,
      "precision": {"selected", "default", "loaded", "options"} (bits; default = recommended; None for hosted/not loaded),
      "benchmark": {"accuracy", "ece", "ms", "items_per_s", "j_per_1k", "memory_mb", "sets", ...} | None   # at the selected precision
      "benchmarks": {"16": {...}, "8": {..., "deltas": {...}}}   # every measured precision, deltas vs the recommended
      "links": {"upstream", "weights", "runtime", ...}, "recommendation"}]
    Links point at Hugging Face / GitHub model cards so an agent can read the specifics."""
    s = status(); bench = _benchmarks(); selected = _selected_precision(); out = []
    for m in s['catalog']:
        state = ('hot' if m['id'] in s['models'] else 'downloaded' if m['id'] in s.get('installed', {})
                 else 'hosted' if not m.get('repository') else 'available')
        hosted = not m.get('repository')
        native = native_bits(m.get('runtime'))
        default, results = _precisions(bench.get(m['id']), native)
        if not hosted:   # the recommended precision is the default: selection, loads and deltas
            default = recommended_bits(results, native, precision_options(m.get('runtime'))) or native
        sel = default if hosted else _eff(selected[m['id']], native) if m['id'] in selected else default
        loaded = s['models'].get(m['id'])
        base = results.get(default)
        all_results = {str(k): dict(v, **({'deltas': deltas(v, base)} if k != default else {}))
                       for k, v in sorted(results.items(), reverse=True)}
        out.append({'id': m['id'], 'name': m['name'], 'family': m.get('links', {}).get('family'),
                    'inputs': m.get('inputs', ['text']), 'params': m['params'], 'context': m['context'],
                    'languages': m['languages'], 'license': m['license'], 'state': state,
                    'loadable': bool(m.get('repository')),
                    'precision': None if hosted else {'selected': sel, 'default': default,
                                                      'loaded': _eff(loaded.get('bits') or 0, native) if loaded else None,
                                                      'options': precision_options(m.get('runtime'))},
                    'benchmark': all_results.get(str(sel)), 'benchmarks': all_results,
                    'links': {k: v for k, v in m.get('links', {}).items() if k != 'family'},
                    'recommendation': m['recommendation']})
    return out


# --------------------------------------------------------------------------- judge / gate

def judge(items, questions, model='auto', batch=256, check=True):
    """Answer `questions` about one item (returns a Result) or a list of items (returns a list).

    Items are strings or dicts (Laya sees a dict as JSON, Von as key: value lines), so name the fields.
    Question ids and choice labels are distinct as exact strings, as in any Python dict.
    Verdict judges text; an item with image/audio/video paths, or over a model's context, comes back as a Result with .error set; the rest still run.
    Raises VerdictError when the worker is unavailable — never returns made-up answers."""
    questions = {k: dict(v) for k, v in questions.items()}
    if check:
        lint(questions)
    single = isinstance(items, (str, dict))
    items = [items] if single else list(items)
    if not items:
        return []
    ensure_running()
    out = []
    for i in range(0, len(items), batch):
        out += _call('POST', '/judge', {'items': items[i:i + batch], 'questions': questions, 'model': model})['results']
    results = [Result(r) for r in out]
    return results[0] if single else results


class Verdict:
    """Outcome of gate(): truthy when allowed. .answers, .reason, .escalated."""
    def __init__(self, allowed, reason, answers, escalated=False):
        self.allowed, self.reason, self.answers, self.escalated = allowed, reason, answers, escalated
    def __bool__(self): return self.allowed
    def __repr__(self): return f'Verdict({"allow" if self.allowed else "deny"}, {self.reason!r})'


def gate(state, checks, allow_if, model='auto', on_error='raise'):
    """Decide-then-escalate in one call.

    checks: questions about `state`; allow_if: function of the Result returning True to allow.
    Returns a Verdict. on_error='raise' (default) surfaces an unavailable worker; on_error='allow'
    or 'deny' fails open/closed and marks the verdict escalated so the caller can log it."""
    try:
        r = judge(state, checks, model=model)
    except VerdictError as e:
        if on_error == 'raise':
            raise
        return Verdict(on_error == 'allow', f'Verdict unavailable: {e}', None, escalated=True)
    if r.error:
        if on_error == 'raise':
            raise VerdictError(r.error)
        return Verdict(on_error == 'allow', r.error, r, escalated=True)
    ok = bool(allow_if(r))
    return Verdict(ok, 'allowed by checks' if ok else 'checks failed: ' + ', '.join(f'{k}={v!r}' for k, v in r.answers.items()), r)


def calibrate(cases, question, model='auto'):
    """Sweep thresholds for one Noul question over labelled cases [(item, expected_bool), ...].

    Returns {"threshold": best, "accuracy": acc, "table": [(t, acc), ...]} so the number in
    your script comes from your data, not from a guess."""
    items = [c[0] for c in cases]; expected = [bool(c[1]) for c in cases]
    probs = [float(r.answers[next(iter(r.answers))]) for r in judge(items, {'q': question}, model=model, check=False)]
    table = []
    for t in [i / 20 for i in range(1, 20)]:
        acc = sum((p > t) == e for p, e in zip(probs, expected)) / len(cases)
        table.append((t, round(acc, 3)))
    best = max(table, key=lambda x: x[1])
    return {'threshold': best[0], 'accuracy': best[1], 'table': table, 'n': len(cases)}


# --------------------------------------------------------------------------- CLI

def _fmt(a):
    if 'choice' in a: return f"{a['choice']}({a.get('confidence', 0):.2f})"
    if 'noul' in a: return f"{a['noul']:.2f}"
    return f"{a.get('score', 0):.2f}"


def _line(row, field=None):
    """One short line per item: index, answers, and a snippet so the agent can tell items apart."""
    if 'error' in row:
        return f"#{row['index']}  error: {row['error']}"
    ans = '  '.join(f"{k}={_fmt(v)}" for k, v in row['answers'].items())
    item = row['item']
    text = item.get(field) if (field and isinstance(item, dict)) else item
    snippet = (text if isinstance(text, str) else json.dumps(text, ensure_ascii=False)).replace('\n', ' ')
    return f"#{row['index']}  {ans}  | {snippet[:60]}" 

def _num(v, fmt):
    return '—' if v is None else fmt.format(v)


def _ms(v):
    return '—' if v is None else (f'{v:.1f} ms' if v < 10 else f'{v:.0f} ms')


def _mem(mb):
    return '—' if mb is None else (f'{mb / 1000:.2f} GB' if mb >= 1000 else f'{mb:.0f} MB')


def _precision_rows(m):
    """One line per offered precision: figures with deltas vs the recommended; marks recommended/selected/loaded."""
    p = m['precision']
    options = p['options'] if p else [int(k) for k in m['benchmarks']]
    rows = []
    for bits in options:
        r = m['benchmarks'].get(str(bits)) or {}
        d = r.get('deltas', {})
        cell = lambda v, delta: (v + (' ' + delta if delta else ''))
        tags = [t for t, on in (('recommended', p and bits == p['default']), ('selected', p and bits == p['selected']),
                                ('loaded', p and bits == p['loaded'])) if on]
        rows.append(f"{bits if p else '—':>4}  {cell(_num(r.get('accuracy'), '{:.1%}'), d.get('accuracy')):16} {cell(_num(r.get('ece'), '{:.3f}'), d.get('ece')):15} "
                    f"{cell(_ms(r.get('ms')), d.get('speed')):20} {cell(_num(r.get('j_per_1k'), '{:.0f} J'), d.get('energy')):24} {_mem(r.get('memory_mb')):>8}"
                    + ('  ' + ', '.join(tags) if tags else ''))
    return rows


def _main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__.strip()); return 0
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == 'status':
            s = status()
            chip = (s.get('gpu') or {}).get('chip')
            def opt(v):
                label = engine_label(v, chip)
                return label + (f": {v['engine_reason']}" if label == 'MLX' and v.get('engine_reason') else '')
            hot = ', '.join(f"{k} ({opt(v)})" + (f" [{v['residency'].replace('_', ' ')}]" if v.get('residency') else '')
                            for k, v in s['models'].items()) or 'none loaded (a judge loads its model on demand)'
            mem = s.get('memory', {})
            free = f", ~{mem['available_mb'] / 1000:.1f} GB free now" if mem.get('available_mb') is not None else ''
            last = f"  last: {s['last_ms']} ms" if s.get('last_ms') is not None else ''
            print(f"port {s['port']}  models: {hot}  calls: {s.get('calls', 0)}{last}  memory: {mem.get('rss_mb', 0):.0f} MB rss, {mem.get('mlx_active_mb', 0):.0f} MB weights{free}"
                  + (f"  loading: {s['loading']}" if s.get('loading') else '') + (f"  error: {s['error']}" if s.get('error') else ''))
            if 'on_demand_idle_minutes' in s:
                window = lambda m: 'always' if not m else f'{m} min idle'
                print(f"keep hot: manual {window(s.get('manual_idle_minutes'))}, on demand {window(s['on_demand_idle_minutes'])}"
                      f"  memory: {'allow swap' if s.get('allow_swap') else 'fit in free memory'}")
            for e in (s.get('evictions') or [])[-3:]:
                print(f"unloaded {e['model']} ({e.get('residency', '').replace('_', ' ')}): {e['reason']}")
            if s.get('refused'):
                print(f"refused: {s['refused']['message']}")
            return 0
        if cmd == 'models':
            ms = models()
            if '--json' in rest:
                print(json.dumps(ms, indent=2, ensure_ascii=False)); return 0
            if '--all' in rest:
                print(f"{'model':22} {'bits':>4}  {'accuracy':16} {'ece':15} {'speed':20} {'energy/1k':24} {'memory':>8}")
                for m in sorted(ms, key=lambda m: -((m['benchmark'] or {}).get('accuracy') or 0)):
                    for n, row in enumerate(_precision_rows(m)):
                        print(f"{m['id'] if n == 0 else '':22} {row}")
                print("\ndeltas vs each model's recommended precision (lowest energy within 0.5 pt of its best accuracy); speed is single-item p50, energy is batched.")
                return 0
            print(f"{'model':22} {'inputs':16} {'context':>7} {'bits':>4} {'accuracy':>8} {'ece':>6} {'speed':>8} {'J/1k':>6} {'memory':>8}  {'state':10} weights")
            for m in sorted(ms, key=lambda m: -((m['benchmark'] or {}).get('accuracy') or 0)):
                b = m['benchmark'] or {}
                p = m['precision']
                bits = str(p['selected']) if p else '—'
                print(f"{m['id']:22} {','.join(m['inputs']):16} {m['context']:>7} {bits:>4} {_num(b.get('accuracy'), '{:.1%}'):>8} {_num(b.get('ece'), '{:.3f}'):>6} "
                      f"{_ms(b.get('ms')):>8} {_num(b.get('j_per_1k'), '{:.0f}'):>6} {_mem(b.get('memory_mb')):>8}  {m['state']:10} {m['links'].get('weights') or m['links'].get('upstream', '')}")
            print("\nfigures at the selected precision (bits). verdict models --all for every precision; verdict info <model> for details.")
            return 0
        if cmd == 'info':
            if not rest:
                raise VerdictError('verdict info <model>')
            m = next((x for x in models() if x['id'] == rest[0]), None)
            if not m:
                raise VerdictError(f"unknown model {rest[0]!r}; see verdict models")
            if '--json' in rest:
                print(json.dumps(m, indent=2, ensure_ascii=False)); return 0
            b = m['benchmark'] or {}
            print(f"{m['name']} ({m['id']}) — {m['state']}")
            print(f"  family      {m['family']}    licence {m['license']}")
            print(f"  inputs      {', '.join(m['inputs'])}    context {m['context']} tokens    languages {m['languages']}    params {m['params']}")
            if m['benchmarks']:
                print(f"  {'bits':>4}  {'accuracy':16} {'ece':15} {'speed':20} {'energy/1k':24} {'memory':>8}")
                for row in _precision_rows(m):
                    print(f"  {row}")
            if b:
                sets = ', '.join(f"{k} {v*100:.1f}%" for k, v in sorted((b.get('sets') or {}).items()))
                split = ', '.join(x for x in (f"English {b['accuracy_en']:.1%}" if b.get('accuracy_en') is not None else '',
                                               f"multilingual {b['accuracy_ml']:.1%}" if b.get('accuracy_ml') is not None else '') if x)
                if sets: print(f"  tasks       {sets}" + (f"  ({b['n_tasks']} tasks)" if b.get('n_tasks') else ''))
                if split: print(f"  split       {split}")
                src = ', '.join(str(x) for x in (b.get('source'), f"n={b['n']}" if b.get('n') else None, b.get('date'), b.get('hardware')) if x)
                if b.get('items_per_s'): src += f"; batched {b['items_per_s']:.0f} items/s"
                if src: print(f"  source      {src}")
                if b.get('note'): print(f"              {b['note']}")
            print(f"  use for     {m['recommendation']}")
            for k, v in m['links'].items():
                print(f"  {k:11} {v}")
            return 0
        if cmd in ('load', 'unload'):
            ids = [a for a in rest if not a.startswith('--')]
            if not ids:
                raise VerdictError(f'verdict {cmd} ID')
            body = {'model': ids[0]}
            if cmd == 'load' and '--manual' in rest:
                body['manual'] = True
            ensure_running(); print(_call('POST', '/' + cmd, body)['loaded']); return 0
        if cmd == 'quit':
            if _port(): _call('POST', '/quit')
            return 0
        if cmd == 'judge':
            qpath = model = sort = None; top = None; minimum = None; field = None; as_json = False
            i = 0
            while i < len(rest):
                a = rest[i]
                if a == '--questions': qpath = rest[i + 1]; i += 2
                elif a == '--model': model = rest[i + 1]; i += 2
                elif a == '--sort': sort = rest[i + 1]; i += 2
                elif a == '--top': top = int(rest[i + 1]); i += 2
                elif a == '--min': minimum = float(rest[i + 1]); i += 2
                elif a == '--field': field = rest[i + 1]; i += 2
                elif a == '--json': as_json = True; i += 1
                else: raise VerdictError(f'unknown option {a}')
            if not qpath:
                raise VerdictError('--questions FILE is required')
            questions = json.loads(Path(qpath).read_text())
            items = [json.loads(l) for l in sys.stdin if l.strip()]
            states = [(it.get(field) if field else it) for it in items]
            results = judge(states, questions, model or 'auto')
            rows = [{'index': n, 'item': it, **r.raw} for n, (it, r) in enumerate(zip(items, results))]
            if sort:
                key = lambda r: r['answers'][sort].get('score', r['answers'][sort].get('noul', r['answers'][sort].get('confidence', 0))) if 'answers' in r else -1
                rows.sort(key=key, reverse=True)
                if minimum is not None:
                    rows = [r for r in rows if key(r) >= minimum]
            if top:
                rows = rows[:top]
            if as_json:
                for r in rows:
                    print(json.dumps(r, ensure_ascii=False))
                return 0
            for r in rows:
                print(_line(r, field))
            return 0
        if cmd == 'skill':
            text = None
            for p in (APP / 'Contents/Resources/SKILL.md', Path(__file__).resolve().parents[1] / 'Resources/SKILL.md'):
                try:
                    text = p.read_text(); break
                except OSError:
                    continue
            if text is None:
                raise VerdictError('SKILL.md not found; is Verdict installed?')
            if '--install' in rest:
                i = rest.index('--install')
                if i + 1 >= len(rest):
                    raise VerdictError('verdict skill --install DIR')
                dest = Path(rest[i + 1]).expanduser() / 'triage' / 'SKILL.md'
                dest.parent.mkdir(parents=True, exist_ok=True); dest.write_text(text)
                print(f'wrote {dest}')
            else:
                print(text)
            return 0
        raise VerdictError(f'unknown command {cmd}')
    except VerdictError as e:
        print('error:', e, file=sys.stderr); return 1


if __name__ == '__main__':
    sys.exit(_main(sys.argv[1:]))
