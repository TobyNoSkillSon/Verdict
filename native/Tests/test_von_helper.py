"""Pinned-SDK Von parity gate, deliberately opt-in for GPU/large checkpoints.

VERDICT_VON_PARITY=1 python3 -m unittest -v native.Tests.test_von_helper
Requires ~/.cache/verdict-bench/von/ckpt-{1.1,1.2}, no downloads. The default (f32) build is held to the strict
SDK gate below (Δp ≤ 0.0001, raw logits ≤ 5e-4); never silently broaden it after float-order differences. The opt-in
fp16 precision (bits 16) is checked against the documented ≤1% comparison instead (full set: native/perf/vonref.py).
"""
import gzip
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import urllib.request
import urllib.error
from decimal import Decimal

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get('VERDICT_HELPER', ROOT / 'native/.build/release-helper/verdict-helper'))
REVISIONS = {'1.1':'d8bb5e0745d8ee1fb65d536d6d4892d54d5a93fd',
             '1.2':'5df8185a4f2327ad0a7cd117cc4f701ac557b9ae'}
FILES = ('option_marker.pt','config.json','tokenizer.json','tokenizer_config.json','marker_calibration.json')

@unittest.skipUnless(os.environ.get('VERDICT_VON_PARITY') == '1','Set VERDICT_VON_PARITY=1 for the Von GPU parity gate')
class VonParityTests(unittest.TestCase):
    def test_sdk_single_and_batched(self):
        for version,sha in REVISIONS.items():
            with self.subTest(version=version), tempfile.TemporaryDirectory(prefix='verdict-von-parity-') as base:
                root=Path(base); support=root/'support';support.mkdir()
                checkpoint=Path.home()/'.cache/verdict-bench/von'/('ckpt-'+version)
                fixture=json.load(gzip.open(ROOT / f'native/fixtures/von-{version}-sdk.json.gz'))
                snapshot=root/'hub/models--wfzyx--von/snapshots'/sha;snapshot.mkdir(parents=True)
                for name in FILES:
                    (snapshot/name).symlink_to(checkpoint/name)
                env=dict(os.environ,VERDICT_SUPPORT_DIR=str(support),HF_HUB_CACHE=str(root/'hub'),
                         VERDICT_CATALOG=str(ROOT/'Resources/models.json'),VERDICT_PRELOAD='',VERDICT_PORT='0',
                         VERDICT_VON_PARITY_TRACE='1')
                env.pop('MLX_ENABLE_TF32',None)
                proc=subprocess.Popen([str(BINARY)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                try:
                    port=json.loads(proc.stdout.readline())['port'];url=f'http://127.0.0.1:{port}'
                    def request(route,obj):
                        with urllib.request.urlopen(urllib.request.Request(url+route,
                            data=json.dumps(obj,ensure_ascii=False).encode(),headers={'Content-Type':'application/json'}),timeout=180) as reply:
                            return json.load(reply)
                    id='von-'+version
                    self.assertIn(id,request('/load',{'model':id})['loaded'])
                    questions=fixture['questions']
                    violations=[]
                    max_p={'one-question':Decimal(0),'three-question':Decimal(0),'five-item':Decimal(0)}
                    def compare(actual,expected,context,mode):
                        for field in ('probabilities','noul'):
                            if field not in expected: continue
                            wanted=expected[field];observed=actual.get(field)
                            pairs=wanted.items() if isinstance(wanted,dict) else [('true',wanted)]
                            if isinstance(wanted,dict) and (not isinstance(observed,dict) or set(observed)!=set(wanted)):
                                violations.append(f'{mode} {context}: probability labels differ');continue
                            for key,value in pairs:
                                got=observed[key] if isinstance(wanted,dict) else observed
                                if not isinstance(got,(int,float)) or not math.isfinite(got):
                                    violations.append(f'{mode} {context}/{field}/{key}: non-finite or absent');continue
                                delta=abs(Decimal(str(got))-Decimal(str(value)))
                                max_p[mode]=max(max_p[mode],delta)
                                if delta>Decimal('0.0001'):
                                    violations.append(f'{mode} {context}/{field}/{key}: Δp={delta} > 0.0001')
                        if 'choice' in expected and actual.get('choice')!=expected['choice']:
                            violations.append(f'{mode} {context}: choice argmax differs')
                        if 'score' in expected:
                            p=actual.get('probabilities',{});ref=expected['probabilities']
                            if p and max(p,key=p.get)!=max(ref,key=ref.get):
                                violations.append(f'{mode} {context}: score-level argmax differs')
                            if not isinstance(actual.get('score'),(int,float)):
                                violations.append(f'{mode} {context}: missing weighted score')
                        if 'noul' in expected and (actual['noul']>0.5)!=(expected['noul']>0.5):
                            violations.append(f'{mode} {context}: noul-side differs')
                        if not isinstance(actual.get('confidence'),(int,float)) or not 0<=actual['confidence']<=1:
                            violations.append(f'{mode} {context}: missing or invalid confidence')
                    for entry in fixture['items']:
                        one=request('/judge',{'items':[entry['item']],'questions':questions,'model':id})['results'][0]
                        for name,expected in entry['item_batched_answers'].items():
                            compare(one['answers'][name],expected,f'{entry["item"]!r}/{name}','three-question')
                            alone=request('/judge',{'items':[entry['item']],
                                'questions':{name:questions[name]},'model':id})['results'][0]
                            compare(alone['answers'][name],entry['single_question_batched_answers'][name],
                                    f'{entry["item"]!r}/{name}','one-question')
                    multi=request('/judge',{'items':[e['item'] for e in fixture['items']],
                        'questions':questions,'model':id})['results']
                    for i,(entry,actual) in enumerate(zip(fixture['items'],multi)):
                        for name,expected in entry['batched_answers'].items():
                            compare(actual['answers'][name],expected,f'item={i}/{name}','five-item')
                    # The unchanged public client and CLI use the same isolated status file.
                    env['PYTHONPATH']=str(ROOT/'client')
                    code="from verdict import judge, Choice; print(judge('Apple shares rose 4% after record iPhone sales.', {'choice': Choice('Which section?', biz='business', sport='sports', other='anything else')}, model='"+id+"').choice.choice)"
                    client=subprocess.run([sys.executable,'-c',code],env=env,text=True,capture_output=True,timeout=45)
                    self.assertEqual(client.returncode,0,client.stderr)
                    cli=subprocess.run([sys.executable,str(ROOT/'client/verdict.py'),'judge','--model',id,
                        '--questions',str(ROOT/'native/fixtures/von-questions.json'),'--json'],
                        input='"Apple shares rose 4% after record iPhone sales."\n',env=env,text=True,capture_output=True,timeout=45)
                    self.assertEqual(cli.returncode,0,cli.stderr)
                    self.assertIn('answers',cli.stdout)
                    long=request('/judge',{'items':['short','word '*10000],
                        'questions':{'n':{'type':'noul','instructions':'Is this about money?'}},'model':id})['results']
                    self.assertIn('noul',long[0]['answers']['n'])
                    self.assertIn('confidence',long[0]['answers']['n'])
                    self.assertIn('8192',long[1]['error'])
                    status=json.load(urllib.request.urlopen(url+'/status'))
                    sdk_single_differences=sum(
                        any(entry['answers'][name].get(k)!=v for k,v in entry['batched_answers'][name].items()
                            if k in entry['answers'][name])
                        for entry in fixture['items'] for name in questions)
                    print('VON_PARITY',id,'max_p',str(max_p),'violations',len(violations),
                          'sdk_single_path_differences',sdk_single_differences,
                          'sdk_single_batched_max_diff',fixture['sdk_single_batched_max_diff'],
                          'resident',status['memory'],flush=True)
                    with self.assertRaises(urllib.error.HTTPError) as precision_error:
                        request('/load',{'model':id,'bits':8})
                    self.assertEqual(precision_error.exception.code,400)
                    precision_error.exception.close()
                    # bits 16: opt-in fp16, not the default. It is outside the ≤1% gate (max |dp| 0.08 on near-tie
                    # items of the 368-item set, native/perf/THEORY.md): check the same answers and |dp| ≤ 0.1.
                    self.assertIn(id,request('/load',{'model':id,'bits':16})['loaded'])
                    half=request('/judge',{'items':[e['item'] for e in fixture['items']],'questions':questions,'model':id})['results']
                    half_dp=0.0
                    for entry,actual in zip(fixture['items'],half):
                        for name,expected in entry['batched_answers'].items():
                            got=actual['answers'][name]
                            if 'noul' in expected:
                                half_dp=max(half_dp,abs(got['noul']-expected['noul']))
                                if (got['noul']>=0.5)!=(expected['noul']>=0.5): violations.append(f'fp16 {name}: noul side differs')
                            else:
                                ref=expected['probabilities'];half_dp=max(half_dp,max(abs(got['probabilities'][k]-v) for k,v in ref.items()))
                                if max(ref,key=ref.get)!=max(ref,key=lambda k:got['probabilities'][k]): violations.append(f'fp16 {name}: argmax differs')
                    print('VON_FP16',id,'max_dp',round(half_dp,4),flush=True)
                    if half_dp>0.1: violations.append(f'fp16 max |dp| {half_dp} > 0.1')
                    request('/quit',{})
                    proc.wait(timeout=12)
                    traces=[json.loads(line.split(' ',1)[1]) for line in proc.stderr.read().splitlines()
                            if line.startswith('VON_PARITY_TRACE ')]
                    raw_delta=0.0
                    raw_by_mode={1:(0.0,None),len(questions):(0.0,None),len(fixture['items'])*len(questions):(0.0,None)}
                    for i,entry in enumerate(fixture['items']):
                        for name,expected in entry['packed'].items():
                            for count,key in [(1,'single_question_batched_logits'),
                                              (len(questions),'item_batched_logits'),
                                              (len(fixture['items'])*len(questions),'batched_logits')]:
                                matching=next((row for row in traces if row['batch_size']==count and row['ids']==expected['ids']),None)
                                if matching is None:
                                    violations.append(f'item={i}/{name}/batch={count}: missing exact token IDs');continue
                                if matching['markers']!=expected['markers']:
                                    violations.append(f'item={i}/{name}/batch={count}: marker positions differ')
                                reference=entry[key][name]
                                if len(matching['logits'])!=len(reference):
                                    violations.append(f'item={i}/{name}/batch={count}: logit count differs');continue
                                delta=max(abs(a-b) for a,b in zip(matching['logits'],reference))
                                raw_delta=max(raw_delta,delta)
                                if delta>raw_by_mode[count][0]:raw_by_mode[count]=(delta,(i,name))
                                if matching['logits'].index(max(matching['logits'])) != reference.index(max(reference)):
                                    violations.append(f'item={i}/{name}/batch={count}: raw argmax differs')
                    if raw_delta>5e-4:violations.append(f'raw logit Δ={raw_delta} > 5e-4')
                    print('VON_RAW',id,'token_rows',len(fixture['items'])*len(questions)*3,
                          'max_logit_delta',raw_delta,'by_mode',raw_by_mode,flush=True)
                    self.assertFalse(violations,'\n'.join(violations[:12]))
                finally:
                    if proc.poll() is None: proc.terminate()
                    proc.wait(timeout=12)
                    proc.stdout.close();proc.stderr.close()
