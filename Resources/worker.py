"""Verdict worker: keeps decision models hot and answers judge requests on loopback.

Protocol (HTTP/1.1, 127.0.0.1 only, JSON bodies):
  GET  /status                    loaded models, counters, latency
  POST /judge   {"items": [...], "questions": {...}, "model": "auto"|id}
                -> {"results": [{"answers": {...}, "model": id, "ms": float}, ...]}
  POST /load    {"model": id}     load (downloads on first use)
  POST /unload  {"model": id}
  POST /quit

The worker writes status.json next to its config so the menu-bar app can show
state without a request. It never listens on anything but loopback.
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

os.environ.setdefault('USE_TF', '0')
os.environ.setdefault('HF_HUB_DISABLE_PROGRESS_BARS', '1')
os.environ.setdefault('TOKENIZERS_PARALLELISM', 'false')

SUPPORT = Path(os.environ.get('VERDICT_SUPPORT_DIR') or Path.home() / 'Library/Application Support/Verdict')
STATUS = SUPPORT / 'status.json'
CATALOG = json.loads((Path(__file__).with_name('models.json')).read_text())
BY_ID = {m['id']: m for m in CATALOG}
LOCK = threading.Lock()
STATE = {'models': {}, 'calls': 0, 'items': 0, 'last_ms': None, 'started': time.time(), 'port': None, 'pid': os.getpid(), 'loading': None, 'error': None, 'last_used': time.time(), 'idle_minutes': int(os.environ.get('VERDICT_IDLE_MINUTES') or 0)}
AGENTS = {}
CACHE_LIMIT_MB = int(os.environ.get('VERDICT_CACHE_LIMIT_MB') or 1024)
SHED_FREE_PCT = float(os.environ.get('VERDICT_SHED_FREE_PCT') or 8)     # below this free %, keep one model
TRIM_FREE_PCT = float(os.environ.get('VERDICT_TRIM_FREE_PCT') or 15)    # below this, drop MLX cache
PRECISION = {k: int(v) for k, v in json.loads(os.environ.get('VERDICT_PRECISION') or '{}').items()}


_RSS = {'t': 0.0, 'mb': 0.0}


def memory():
    """Resident set of this worker and what MLX itself holds; the difference is runtime overhead."""
    out = {}
    try:
        if time.time() - _RSS['t'] > 1.0:
            import subprocess
            _RSS['mb'] = round(int(subprocess.check_output(['ps', '-o', 'rss=', '-p', str(os.getpid())]).strip()) / 1024, 0)
            _RSS['t'] = time.time()
        out['rss_mb'] = _RSS['mb']
    except Exception:
        pass
    try:
        import mlx.core as mx
        out['mlx_active_mb'] = round(mx.get_active_memory() / 1e6, 0)
        out['mlx_cache_mb'] = round(mx.get_cache_memory() / 1e6, 0)
    except Exception:
        pass
    return out


STATUS_LOCK = threading.Lock()


def write_status():
    SUPPORT.mkdir(parents=True, exist_ok=True)
    try:
        inst = installed()
    except Exception:
        inst = {}
    with STATUS_LOCK:
        tmp = STATUS.with_name(f'status.{os.getpid()}.{threading.get_ident()}.tmp')
        tmp.write_text(json.dumps(STATE | {'updated': time.time(), 'installed': inst, 'memory': memory()}))
        tmp.replace(STATUS)


def load(model_id):
    if model_id in AGENTS:
        return AGENTS[model_id]
    spec = BY_ID.get(model_id)
    if not spec or not spec.get('repository'):
        raise ValueError(f'Unknown or hosted-only model {model_id!r}; loadable: {", ".join(k for k, v in BY_ID.items() if v.get("repository"))}')
    STATE['loading'] = model_id; STATE['downloading'] = not cache_paths(spec); STATE['error'] = None; write_status()
    t = time.time()
    try:
        if spec.get('runtime') == 'gemma_rlcd':
            agent = GemmaAgent(spec)
        else:
            import laya_mlx as laya
            kwargs = {'subfolder': spec['subfolder']} if spec['subfolder'] else {}
            agent = laya.load(spec['repository'], compile=True, **kwargs)
            # Run at the encoder's real limit. The shipped 512/1024 is a training
            # budget; measured accuracy holds to 8k. Over-long items are refused
            # per item in judge(), never silently cut.
            agent.cfg['max_len'] = spec.get('context', agent.cfg.get('max_len', 512))
            bits = int(PRECISION.get(model_id, 0) or 0)
            if bits in (4, 8):
                import mlx.nn as nn, mlx.core as mx
                nn.quantize(agent.model, bits=bits, group_size=64,
                            class_predicate=lambda _, m: isinstance(m, nn.Linear) and m.weight.shape[-1] % 64 == 0)
                mx.eval(agent.model.parameters())
    except Exception as e:
        STATE['loading'] = None; STATE['downloading'] = False; STATE['error'] = f'{model_id}: {str(e)[:200]}'; write_status()
        raise
    AGENTS[model_id] = agent
    STATE['models'][model_id] = {'device': 'mlx', 'load_s': round(time.time() - t, 1), 'bits': PRECISION.get(model_id, 0) if spec.get('runtime', 'laya') == 'laya' else 4}
    STATE['loading'] = None; STATE['downloading'] = False; write_status()
    return agent


class GemmaAgent:
    """Adapter: same predict(state, questions) contract over larkooo/gemma-e2b-rlcd.

    State dict keys image/images, audio, video/videos are media paths; every
    other key is rendered as JSON text. Questions use the Laya shapes."""
    MEDIA = {'image': 'images', 'images': 'images', 'audio': 'audio', 'video': 'videos', 'videos': 'videos'}

    def __init__(self, spec):
        from huggingface_hub import snapshot_download
        path = snapshot_download(spec['repository'])
        if path not in sys.path:
            sys.path.insert(0, path)
        import gemma_rlcd
        from gemma_rlcd.json_backend import JSONMLXBackend
        self.g = gemma_rlcd
        self.engine = gemma_rlcd.DecisionEngine(JSONMLXBackend(path))

    def state(self, item):
        if isinstance(item, str):
            return self.g.State(text=item)
        media = {'images': [], 'audio': [], 'videos': []}
        rest = {}
        for k, v in item.items():
            if k in self.MEDIA:
                media[self.MEDIA[k]] += [v] if isinstance(v, str) else list(v)
            else:
                rest[k] = v
        text = rest.pop('text', '') if list(rest) == ['text'] else (json.dumps(rest, ensure_ascii=False) if rest else '')
        return self.g.State(text=text, images=tuple(media['images']), audio=tuple(media['audio']), videos=tuple(media['videos']))

    def questions(self, questions):
        out = {}
        for k, q in questions.items():
            t = q['type']; ins = q.get('instructions', '')
            if t == 'noul':
                out[k] = self.g.Noul(ins)
            elif t == 'choice':
                crit = q['criteria']
                out[k] = self.g.Choice(ins, crit if isinstance(crit, dict) else {c: c for c in crit})
            elif t == 'score':
                out[k] = self.g.Score(ins, list(q['criteria']))
            else:
                raise ValueError(f'Unknown question type {t!r}')
        return out

    def predict(self, item, questions):
        res = self.engine.system_one(self.state(item), self.questions(questions))
        answers = {}
        for k, a in res['answers'].items():
            t = a['type']
            if t == 'noul':
                answers[k] = {'noul': a['noul'], 'confidence': max(a['noul'], 1 - a['noul'])}
            elif t == 'choice':
                answers[k] = {'choice': a['choice'], 'probabilities': a['probabilities'], 'confidence': a['selected_probability']}
            else:
                answers[k] = {'score': a['score'], 'probabilities': a['probabilities'], 'confidence': max(a['probabilities'].values())}
            answers[k]['calibrated'] = False
        return {'answers': answers}


def cache_paths(spec):
    """Local files of a checkpoint if already downloaded, else []."""
    from huggingface_hub import try_to_load_from_cache
    found = []
    files = ('model.safetensors', 'config.json') if spec.get('runtime') == 'gemma_rlcd' else ('model.safetensors', 'manifest.json', 'mlx_config.json')
    for f in files:
        path = try_to_load_from_cache(spec['repository'], f)
        if isinstance(path, str):
            found.append(path)
    return found if any(p.endswith('model.safetensors') for p in found) else []


def installed():
    out = {}
    for m in CATALOG:
        if not m.get('repository'):
            continue
        paths = cache_paths(m)
        if paths:
            size = 0
            for p in paths:
                try:
                    size += os.path.getsize(os.path.realpath(p))
                except OSError:
                    pass
            out[m['id']] = {'bytes': size}
    return out


def delete(model_id):
    spec = BY_ID[model_id]
    unload(model_id)
    for p in cache_paths(spec):
        real = os.path.realpath(p)
        for target in (p, real):
            try:
                os.unlink(target)
            except OSError:
                pass
    STATE.pop('error', None); write_status()


def unload(model_id):
    agent = AGENTS.pop(model_id, None); STATE['models'].pop(model_id, None)
    if agent is not None and hasattr(agent, 'engine'):
        agent.engine = None
    del agent
    import gc
    gc.collect()
    try:
        import mlx.core as mx
        mx.clear_cache()
        mx.reset_peak_memory()
    except Exception:
        pass
    write_status()


def is_english(text):
    """ASCII-only text goes to the English checkpoint; any accented Latin or other
    script goes multilingual. Plain-ASCII Polish/German still needs model=laya-multilingual."""
    letters = [c for c in text if c.isalpha()]
    if not letters:
        return True
    ascii_letters = sum(1 for c in letters if ord(c) < 128)
    return ascii_letters / len(letters) > 0.995


def has_media(item):
    return isinstance(item, dict) and any(k in GemmaAgent.MEDIA for k in item)


def pick_model(item, requested):
    if requested and requested != 'auto':
        return requested
    if has_media(item):
        for m in CATALOG:
            if 'image' in m.get('inputs', []) and m.get('repository'):
                return m['id']
        raise ValueError('No multimodal model in the catalog')
    text = json.dumps(item, ensure_ascii=False) if not isinstance(item, str) else item
    loaded = list(AGENTS)
    if is_english(text):
        for m in ('laya-english', 'laya-multilingual'):
            if m in loaded:
                return m
        return 'laya-english'
    return 'laya-multilingual'


def token_count(agent, item, questions):
    """Tokens the Laya path will need: state plus the largest question prompt."""
    text = item if isinstance(item, str) else json.dumps(item, ensure_ascii=False)
    enc = agent.tok.backend.encode
    state = len(enc(text).ids)
    head = max(len(enc(json.dumps(q, ensure_ascii=False)).ids) for q in questions.values())
    return state + head + 8


LAYA_ROWS = 64  # rows per forward pass; measured ~0.8 ms/row at 64 vs 5.8 ms for a lone row


def laya_predict_many(agent, states, questions):
    """One forward pass for many states sharing the same questions.

    Mirrors laya_mlx.Agent.system_one row post-processing; only the batching differs."""
    if not hasattr(agent, 'forward'):
        return [{k: {kk: vv for kk, vv in v.items() if kk in ('choice', 'score', 'noul', 'confidence', 'probabilities')} for k, v in agent.predict(s, questions)['answers'].items()} for s in states]
    import numpy as np
    from laya_mlx.agent import collate_items, temp_bucket, confidence_from_probs
    rows, meta = [], []
    for si, state in enumerate(states):
        items, internal = agent.prepare(state, questions)
        for qi, (item, q) in enumerate(zip(items, internal)):
            rows.append(item); meta.append((si, qi, q))
    qids = list(questions)
    answers = [dict() for _ in states]
    for start in range(0, len(rows), LAYA_ROWS):
        chunk = rows[start:start + LAYA_ROWS]
        batch = collate_items(chunk, agent.tok.pad_token_id, pad_to_multiple=agent.pad_to_multiple, max_length=agent.cfg.get('max_len', 512))
        logits, act = agent.forward(batch)
        logits = np.asarray(logits)
        for r, item in enumerate(chunk):
            si, qi, q = meta[start + r]
            k, qt = len(item['markers']), item['qtype']
            scale = agent.temperature_by_options.get(temp_bucket(qt, k), agent.temperature[qt])
            z = logits[r, :k] / scale
            p = np.exp(z - z.max()); p /= p.sum()
            a = {'confidence': round(confidence_from_probs(p, k), 4)}
            if q['t'] == 'choice':
                labels = list(q['crit'])
                a.update(choice=labels[int(p.argmax())], probabilities={l: round(float(v), 4) for l, v in zip(labels, p)})
            elif q['t'] == 'score':
                a.update(score=round(float((np.arange(k) * p).sum()), 4), probabilities={str(i): round(float(v), 4) for i, v in enumerate(p)})
            else:
                a.update(noul=round(float(p[1]), 4), confidence=round(max(float(p[1]), 1.0 - float(p[1])), 4))
            answers[si][qids[qi]] = a
    return answers


def judge(items, questions, requested='auto'):
    if not isinstance(items, list) or not items:
        raise ValueError('items must be a nonempty list')
    if not isinstance(questions, dict) or not questions:
        raise ValueError('questions must be a nonempty object')
    out = [None] * len(items)
    with LOCK:
        groups = {}
        for i, item in enumerate(items):
            model_id = pick_model(item, requested)
            groups.setdefault(model_id, []).append(i)
        for model_id, idxs in groups.items():
            agent = load(model_id)
            spec = BY_ID[model_id]
            if spec.get('runtime', 'laya') == 'laya':
                ok = []
                for i in idxs:
                    need = token_count(agent, items[i], questions)
                    if need > spec['context']:
                        out[i] = {'error': f'Item needs about {need} tokens; {model_id} accepts {spec["context"]}. Shorten it or split it.', 'model': model_id, 'ms': 0}
                    else:
                        ok.append(i)
                t = time.time()
                answers = laya_predict_many(agent, [items[i] for i in ok], questions) if ok else []
                per = (time.time() - t) * 1000 / max(1, len(ok))
                for i, a in zip(ok, answers):
                    out[i] = {'answers': a, 'model': model_id, 'ms': round(per, 1)}
                STATE['calls'] += 1; STATE['items'] += len(ok); STATE['last_ms'] = round(per, 1)
            else:
                for i in idxs:
                    t = time.time()
                    res = agent.predict(items[i], questions)
                    ms = (time.time() - t) * 1000
                    answers = {k: {kk: vv for kk, vv in v.items() if kk in ('choice', 'score', 'noul', 'confidence', 'probabilities', 'probs', 'calibrated')} for k, v in res['answers'].items()}
                    out[i] = {'answers': answers, 'model': model_id, 'ms': round(ms, 1)}
                    STATE['calls'] += 1; STATE['items'] += 1; STATE['last_ms'] = round(ms, 1)
        STATE['last_used'] = time.time(); STATE['idle_unloaded'] = False
        trim_cache()
        write_status()
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *a):
        pass

    def send(self, code, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return json.loads(self.rfile.read(n) or b'{}')

    def do_GET(self):
        if self.path == '/status':
            return self.send(200, STATE | {'catalog': CATALOG, 'installed': installed(), 'memory': memory()})
        self.send(404, {'error': 'not found'})

    def do_POST(self):
        try:
            b = self.body()
            if self.path == '/judge':
                return self.send(200, {'results': judge(b.get('items'), b.get('questions'), b.get('model', 'auto'))})
            if self.path == '/load':
                with LOCK:
                    if 'bits' in b:
                        PRECISION[b['model']] = int(b['bits'] or 0)
                        unload(b['model'])
                    load(b['model'])
                return self.send(200, {'loaded': list(AGENTS)})
            if self.path == '/unload':
                with LOCK:
                    unload(b['model'])
                return self.send(200, {'loaded': list(AGENTS)})
            if self.path == '/delete':
                with LOCK:
                    delete(b['model'])
                return self.send(200, {'installed': installed()})
            if self.path == '/shed':
                # Memory pressure: keep the first hot model, drop the rest and all cache.
                with LOCK:
                    shed()
                return self.send(200, {'loaded': list(AGENTS)})
            if self.path == '/trim':
                with LOCK:
                    import mlx.core as mx
                    mx.clear_cache()
                return self.send(200, {'ok': True})
            if self.path == '/settings':
                STATE['idle_minutes'] = int(b.get('idle_minutes', STATE['idle_minutes']) or 0); STATE['last_used'] = time.time(); write_status()
                return self.send(200, {'idle_minutes': STATE['idle_minutes']})
            if self.path == '/quit':
                self.send(200, {'bye': True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return
            self.send(404, {'error': 'not found'})
        except Exception as e:
            self.send(400, {'error': str(e)[:500]})


def free_memory_pct():
    """Free physical memory as a percentage, from the kernel's own counters."""
    try:
        import subprocess
        page = int(subprocess.check_output(['sysctl', '-n', 'hw.pagesize']))
        free = int(subprocess.check_output(['sysctl', '-n', 'vm.page_free_count']))
        total = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize']))
        return 100.0 * free * page / total
    except Exception:
        return 100.0


def shed(keep_first=True):
    keep = list(AGENTS)[:1] if keep_first else []
    for m in list(AGENTS):
        if m not in keep:
            unload(m)
    try:
        import mlx.core as mx
        mx.clear_cache()
    except Exception:
        pass
    STATE['shed_at'] = time.time(); STATE['idle_unloaded'] = True; write_status()
    print(json.dumps({'shed': True, 'kept': keep, 'free_pct': round(free_memory_pct(), 1)}), file=sys.stderr, flush=True)
    return keep


def trim_cache():
    """MLX keeps freed buffers for reuse; without a limit that grew to 20 GB after media calls."""
    try:
        import mlx.core as mx
        if mx.get_cache_memory() > CACHE_LIMIT_MB * 1e6:
            mx.clear_cache()
    except Exception:
        pass


def main():
    try:
        import mlx.core as mx
        mx.set_cache_limit(CACHE_LIMIT_MB * 1024 * 1024)
    except Exception:
        pass
    port = int(os.environ.get('VERDICT_PORT') or 0)
    preload = [m for m in (os.environ.get('VERDICT_PRELOAD') or '').split(',') if m]
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    STATE['port'] = server.server_address[1]
    write_status()
    print(json.dumps({'port': STATE['port'], 'pid': os.getpid()}), flush=True)

    def warm():
        for m in preload:
            try:
                with LOCK:
                    load(m)
            except Exception as e:
                print(json.dumps({'error': str(e)[:300]}), file=sys.stderr, flush=True)
    threading.Thread(target=warm, daemon=True).start()

    def idle_watch():
        # Free memory after a quiet period; the next judge reloads lazily.
        # Also our own pressure guard: the kernel's free-page count, no notification needed.
        while True:
            time.sleep(30)
            free = free_memory_pct()
            if len(AGENTS) > 1 and free < SHED_FREE_PCT and not STATE.get('loading'):
                with LOCK:
                    shed()
                continue
            if free < TRIM_FREE_PCT:
                try:
                    import mlx.core as mx
                    mx.clear_cache()
                except Exception:
                    pass
            minutes = STATE.get('idle_minutes') or 0
            if minutes and AGENTS and time.time() - STATE['last_used'] > minutes * 60 and not STATE.get('loading'):
                with LOCK:
                    for m in list(AGENTS):
                        unload(m)
                    STATE['idle_unloaded'] = True; write_status()
    threading.Thread(target=idle_watch, daemon=True).start()
    try:
        server.serve_forever()
    finally:
        STATE['models'] = {}; STATE['port'] = None; write_status()


if __name__ == '__main__':
    main()
