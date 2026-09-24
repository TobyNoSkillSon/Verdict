#!/usr/bin/env python3
"""Explicit Laya-only integration against a private helper; never opens/touches Verdict.app.

Run after scripts/build-helper.sh. Uses an isolated support dir and HF cache whose
weight files are read-only symlinks to already downloaded blobs. No Gemma calls.
GPU timings are contended and are NOT performance measurements.
"""
import gzip
import json
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time
import traceback

ROOT = pathlib.Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'native'
BINARY = NATIVE / '.build/release-helper/verdict-helper'
SOURCE_CACHE = pathlib.Path.home() / '.cache/huggingface/hub'
CATALOG = ROOT / 'Resources/models.json'
QUESTIONS = {'x': {'type': 'noul', 'instructions': 'Is this about billing?'}}
REPORT = []


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def rss_kib(pid):
    return int(subprocess.check_output(['/bin/ps', '-o', 'rss=', '-p', str(pid)], text=True).strip())


def isolated_cache(dst):
    for spec in json.loads(CATALOG.read_text())[:2]:
        repo = spec['repository'].replace('/', '--')
        name = 'models--' + repo
        source = SOURCE_CACHE / name
        sha = (source / 'refs/main').read_text().strip()
        original = source / 'snapshots' / sha
        target = dst / name / 'snapshots' / sha
        target.mkdir(parents=True)
        (dst / name / 'refs').mkdir()
        (dst / name / 'refs/main').write_text(sha)
        for file in original.rglob('*'):
            if file.is_file():
                link = target / file.relative_to(original)
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(file.resolve())
        print(f'CACHE {spec["id"]} {sha}: symlinked from existing snapshot; source untouched', flush=True)


def start(support, cache, preload):
    selected = port()
    env = dict(os.environ, VERDICT_SUPPORT_DIR=str(support), HF_HUB_CACHE=str(cache),
               VERDICT_CATALOG=str(CATALOG), VERDICT_PORT=str(selected), VERDICT_PRELOAD=preload,
               VERDICT_PRECISION='{}', VERDICT_CACHE_LIMIT_MB='1024', VERDICT_IDLE_MINUTES='0')
    env.pop('VERDICT_STUB_MODELS', None)
    proc = subprocess.Popen([str(BINARY)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = proc.stdout.readline()
    if not line:
        raise RuntimeError(f'helper launch failed: {proc.stderr.read()[:1000]}')
    assert json.loads(line)['port'] == selected, line
    return proc, selected


def stop(proc, verdict):
    try:
        if proc.poll() is None: verdict._call('POST', '/quit', {})
        proc.wait(timeout=12)
    finally:
        if proc.poll() is None: proc.terminate(); proc.wait(timeout=8)
        proc.stdout.close()
        errors = proc.stderr.read()
        proc.stderr.close()
        if errors: print('HELPER_STDERR', errors[-1600:], flush=True)


def case(name, fn):
    try:
        fn()
        REPORT.append((name, 'PASS', ''))
        print('PASS', name, flush=True)
    except Exception as error:
        REPORT.append((name, 'FAIL', str(error)))
        print('FAIL', name, str(error)[:350], flush=True)
        traceback.print_exc(limit=3)


def run():
    if not BINARY.exists(): raise RuntimeError(f'build first: {BINARY}')
    with tempfile.TemporaryDirectory(prefix='verdict-live-laya-') as temp:
        base = pathlib.Path(temp)
        support = base / 'support'; cache = base / 'hub'
        support.mkdir(); cache.mkdir()
        isolated_cache(cache)
        os.environ['VERDICT_SUPPORT_DIR'] = str(support)
        sys.path.insert(0, str(ROOT / 'client'))
        import verdict

        idle, _ = start(support, cache, '')
        try:
            time.sleep(2)
            print(f'RSS idle/no model: {rss_kib(idle.pid)} KiB; CPU-only status smoke', flush=True)
            assert verdict._call('GET', '/status')['models'] == {}
        finally: stop(idle, verdict)

        proc, _ = start(support, cache, 'laya-english,laya-multilingual')
        try:
            deadline = time.monotonic() + 240
            while time.monotonic() < deadline:
                if proc.poll() is not None: raise RuntimeError(f'helper exited during preload: {proc.returncode}')
                status = json.loads((support / 'status.json').read_text())
                if {'laya-english', 'laya-multilingual'} <= set(status['models']): break
                if status.get('error'): raise RuntimeError(f'preload failed: {status["error"]}')
                time.sleep(.3)
            else: raise RuntimeError(f'preload timeout; status={status}')
            print(f'RSS both Laya models loaded: {rss_kib(proc.pid)} KiB (contended, not a benchmark)', flush=True)

            def status_case():
                file = json.loads((support / 'status.json').read_text())
                current = verdict._call('GET', '/status')
                assert file['pid'] == current['pid'] == proc.pid
                assert file['port'] == current['port']
                assert set(file['models']) == set(current['models']) == {'laya-english', 'laya-multilingual'}
            case('status file and two-model preload', status_case)

            def bad():
                for body in ({'items': [], 'questions': QUESTIONS}, {'items': ['x'], 'questions': {}},
                             {'items': ['x'], 'questions': {'q': {'type': 'nope'}}},
                             {'items': ['x'], 'questions': QUESTIONS, 'model': 'no-such'},
                             {'items': ['x'], 'questions': QUESTIONS, 'model': 'jev'}):
                    try: verdict._call('POST', '/judge', body); raise AssertionError(f'accepted {body}')
                    except verdict.VerdictError as error: assert str(error)
                assert 'noul' in verdict.judge('alive', QUESTIONS).answers['x'].raw
            case('bad requests return 400; worker survives', bad)

            def overlong():
                res = verdict.judge([' '.join(['w'] * 9000), 'short'], QUESTIONS)
                assert '8192' in res[0].error and res[1].answers['x'].noul is not None
            case('over-context per-item refusal', overlong)

            def routing():
                res = verdict.judge(['Zażółć gęślą jaźń', 'Faktura podwojna prosze o zwrot', 'duplicate invoice'], QUESTIONS)
                assert [x.model for x in res] == ['laya-multilingual', 'laya-english', 'laya-english']
                assert verdict.judge('Faktura podwojna', QUESTIONS, model='laya-multilingual').model == 'laya-multilingual'
            case('ASCII/multilingual/explicit routing', routing)

            def batch():
                items = [f'item {i} ' + ('refund' if i % 2 else 'crash') for i in range(150)]
                result = verdict.judge(items, {'billing': {'type': 'noul', 'instructions': 'Is this about a refund?'}}, batch=256)
                assert len(result) == 150
                odds = [x.answers['billing'].noul for i, x in enumerate(result) if i % 2]
                evens = [x.answers['billing'].noul for i, x in enumerate(result) if not i % 2]
                assert sum(odds)/len(odds) > sum(evens)/len(evens), 'row order lost'
            case('150-row batching (>64) preserves order', batch)

            def concurrent():
                errors = []
                def worker(n):
                    try:
                        result = verdict.judge([f'thread {n} refund'] * 5, QUESTIONS)
                        assert len(result) == 5 and all(x.answers['x'].noul is not None for x in result)
                    except Exception as error: errors.append(error)
                threads = [threading.Thread(target=worker, args=(n,)) for n in range(6)]
                for thread in threads: thread.start()
                for thread in threads: thread.join(timeout=120)
                assert not errors and all(not thread.is_alive() for thread in threads), errors
            case('six concurrent clients', concurrent)

            def unload():
                verdict._call('POST', '/unload', {'model': 'laya-multilingual'})
                assert 'laya-multilingual' not in verdict._call('GET', '/status')['models']
                result = verdict.judge('Zażółć', QUESTIONS)
                assert result.model == 'laya-multilingual' and result.answers['x'].noul is not None
                assert 'laya-multilingual' in verdict._call('GET', '/status')['models']
            case('unload and lazy reload', unload)

            def unload_during():
                result, errors = [], []
                def judge():
                    try: result.extend(verdict.judge(['refund'] * 40, QUESTIONS))
                    except Exception as error: errors.append(error)
                thread = threading.Thread(target=judge); thread.start(); time.sleep(.05)
                verdict._call('POST', '/unload', {'model': 'laya-english'})
                thread.join(timeout=120)
                assert not errors and len(result) == 40 and not thread.is_alive()
                assert 'laya-english' not in verdict._call('GET', '/status')['models']
                assert verdict.judge('refund', QUESTIONS).answers['x'].noul is not None
            case('unload cannot interleave with batch', unload_during)

            def precision():
                for bits in ('16', '8', '4', '0'):
                    verdict._call('POST', '/load', {'model': 'laya-english', 'bits': bits})
                    state = verdict._call('GET', '/status')['models']
                    assert state['laya-english']['bits'] == int(bits), (bits, state)
                    answer = verdict.judge('refund please', QUESTIONS).answers['x'].noul
                    assert 0 <= answer <= 1 and isinstance(answer, float), (bits, answer)
            case('precision hot switch 16/8/4/0', precision)

            def dict_items():
                with gzip.open(NATIVE / 'fixtures/laya-english-0bit.json.gz', 'rt') as file: fixture = json.load(file)
                samples = [x for x in fixture['items'] if isinstance(x.get('input'), dict)][:3]
                assert len(samples) == 3
                response = verdict._call('POST', '/judge', {'items': [x['input'] for x in samples],
                    'questions': fixture['questions'], 'model': 'laya-english'})['results']
                for got, expected in zip(response, samples):
                    assert got['model'] == expected['wire']['model']
                    assert got['answers'] == expected['wire']['answers'], (expected['id'], got['answers'], expected['wire']['answers'])
            case('ordered dict JSON matches Python wire', dict_items)

            def client():
                result = verdict.judge('Please refund my invoice.', {'decision': verdict.Noul('Does this ask for a refund?')})
                assert result.model == 'laya-english' and 0 <= result.decision <= 1
            case('client/verdict.py unchanged', client)
        finally:
            stop(proc, verdict)
    failed = [r for r in REPORT if r[1] == 'FAIL']
    print(f'RESULT {len(REPORT)-len(failed)}/{len(REPORT)} passed; GPU timings contended and not benchmarks', flush=True)
    return 1 if failed else 0


if __name__ == '__main__': sys.exit(run())
