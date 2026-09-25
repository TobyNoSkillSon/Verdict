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

Question shapes follow the TypeSafe/Laya convention (same names, same fields), so questions written for Jev work
here unchanged. Plain dicts are still accepted.

A thin client of the Verdict app's local HTTP API (docs/API.md); starts the app if it is not running. Standard
library only. The command line is the `verdict` binary that ships with the app.
"""
import http.client
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request
import warnings
from pathlib import Path

SUPPORT = Path(os.environ.get('VERDICT_SUPPORT_DIR') or Path.home() / 'Library/Application Support/Verdict')
STATUS = SUPPORT / 'status.json'


def _app():
    """VERDICT_APP, else the path install.sh recorded, else /Applications (then ~/Applications)."""
    if os.environ.get('VERDICT_APP'):
        return Path(os.environ['VERDICT_APP'])
    try:
        recorded = (Path.home() / '.local/share/verdict/app-path').read_text().strip()
        if recorded:
            return Path(recorded)
    except OSError:
        pass
    for p in (Path('/Applications/Verdict.app'), Path.home() / 'Applications/Verdict.app'):
        if p.exists():
            return p
    return Path('/Applications/Verdict.app')


APP = _app()


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
    """One API call (path like '/v1/judge'). Raises VerdictError with the API's message on any error status, and
    for a connection failure, timeout or unreadable answer. Never retried: a judgement may already have run."""
    port = _port()
    if port is None:
        raise VerdictError('Verdict worker is not running')
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = r.read()
        return json.loads(data)
    except ValueError as e:     # JSONDecodeError and UnicodeDecodeError
        raise VerdictError(f'Unexpected answer from Verdict: {e}') from None
    except urllib.error.HTTPError as e:
        try:
            msg = json.loads(e.read()).get('error')
        except Exception:
            msg = str(e)
        if e.code == 404 and msg == 'not found' and path.startswith('/v1/'):
            msg = 'the running Verdict predates the v1 API; update it (git pull && scripts/install.sh)'
        raise VerdictError(msg) from None
    except (urllib.error.URLError, OSError, http.client.HTTPException) as e:
        # refused, reset, timeout (socket.timeout is an OSError), a dropped or truncated answer (IncompleteRead)
        reason = getattr(e, 'reason', None) or str(e) or type(e).__name__
        raise VerdictError(f'Verdict did not answer: {reason}') from None


def _whole(bits):
    """bits as a whole number: 4 and 4.0 are fine; 4.9, True and '4' are refused, never truncated."""
    if isinstance(bits, int) and not isinstance(bits, bool):
        return bits
    if isinstance(bits, float) and bits.is_integer():
        return int(bits)
    raise VerdictError(f'bits must be a whole number, not {bits!r}')


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
    """GET /v1/status: port, loaded models, memory, Keep Hot, recent unloads, the catalog."""
    ensure_running()
    return _call('GET', '/v1/status')


def models():
    """Every catalog model with its state, measured benchmarks and links, for choosing one.

    [{"id", "name", "family", "inputs", "params", "context", "languages", "license",
      "state": "hot"|"downloaded"|"available"|"hosted", "loadable": bool,
      "precision": {"selected", "default", "loaded", "options"} (bits; default = recommended; None for hosted),
      "benchmark": {"accuracy", "ece", "ms", "items_per_s", "j_per_1k", "memory_mb", "sets", ...} | None   # at the selected precision
      "benchmarks": {"16": {...}, "8": {..., "deltas": {...}}}   # every measured precision, deltas vs the recommended
      "links": {"upstream", "weights", "runtime", ...}, "recommendation"}]
    Links point at Hugging Face / GitHub model cards so an agent can read the specifics."""
    ensure_running()
    out = _call('GET', '/v1/models')['models']
    for m in out:   # highest precision first, as the table shows them
        m['benchmarks'] = dict(sorted(m['benchmarks'].items(), key=lambda kv: -int(kv[0]) if kv[0].isdigit() else 0))
    return out


def load(model, bits=None, manual=False):
    """Load a model (downloading it the first time); returns the loaded ids. bits reloads it at that precision
    (0 = native); manual=True loads it like the menu's Load (launch set, "Manually loaded" Keep Hot)."""
    body = {'model': model}
    if bits is not None: body['bits'] = _whole(bits)
    if manual: body['manual'] = True
    ensure_running()
    return _call('POST', '/v1/load', body)['loaded']


def unload(model):
    """Unload a model; returns the loaded ids."""
    ensure_running()
    return _call('POST', '/v1/unload', {'model': model})['loaded']


# --------------------------------------------------------------------------- judge / gate

def judge(items, questions, model='auto', batch=256, check=True, bits=None):
    """Answer `questions` about one item (returns a Result) or a list of items (returns a list).

    Items are strings or dicts (Laya sees a dict as JSON, Von as key: value lines), so name the fields.
    Question ids and choice labels are distinct as exact strings, as in any Python dict.
    Verdict judges text; an item with image/audio/video paths, or over a model's context, comes back as a Result with .error set; the rest still run.
    bits runs the model(s) at that precision, a whole number (a loaded model at another precision is reloaded and stays at it
    while loaded; a later load without bits uses models()'s precision['selected']).
    Raises VerdictError when the worker is unavailable — never returns made-up answers."""
    questions = {k: dict(v) for k, v in questions.items()}
    bits = None if bits is None else _whole(bits)
    if check:
        lint(questions)
    single = isinstance(items, (str, dict))
    items = [items] if single else list(items)
    if not items:
        return []
    ensure_running()
    out = []
    for i in range(0, len(items), batch):
        body = {'items': items[i:i + batch], 'questions': questions, 'model': model}
        if bits is not None: body['bits'] = bits
        out += _call('POST', '/v1/judge', body)['results']
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
    or 'deny' fails open/closed and marks the verdict escalated so the caller can log it. Unavailable includes a
    refused connection, a timeout and an unreadable answer (a helper restarting mid-request)."""
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
