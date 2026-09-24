"""Von active-memory teardown regression; requires existing pinned checkpoints.

VERDICT_VON_UNLOAD=1 python3 -m unittest -v native.Tests.test_von_unload
Isolated HF cache/support, no downloads or installed-app interaction.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(os.environ.get('VERDICT_HELPER', ROOT/'native/.build/release-helper/verdict-helper'))
REVISIONS = {'von-1.1':'d8bb5e0745d8ee1fb65d536d6d4892d54d5a93fd',
             'von-1.2':'5df8185a4f2327ad0a7cd117cc4f701ac557b9ae'}

@unittest.skipUnless(os.environ.get('VERDICT_VON_UNLOAD') == '1','Explicit two-checkpoint GPU unload regression')
class VonUnloadTests(unittest.TestCase):
    def test_alternating_three_cycles(self):
        with tempfile.TemporaryDirectory(prefix='verdict-von-unload-') as tmp:
            root=Path(tmp);cache=root/'hub';support=root/'support';cache.mkdir();support.mkdir()
            for model,sha in REVISIONS.items():
                source=Path.home()/'.cache/verdict-bench/von'/('ckpt-'+model.split('-')[1])
                snapshot=cache/'models--wfzyx--von'/'snapshots'/sha;snapshot.mkdir(parents=True)
                for name in ('option_marker.pt','config.json','tokenizer.json','tokenizer_config.json','marker_calibration.json'):
                    self.assertTrue((source/name).is_file(),f'Missing existing checkpoint file: {source/name}')
                    (snapshot/name).symlink_to(source/name)
            catalog=json.loads((ROOT/'Resources/models.json').read_text())
            laya=next(m for m in catalog if m['id']=='laya-english')
            source=Path.home()/'.cache/huggingface/hub'/('models--'+laya['repository'].replace('/','--'))
            sha=(source/'refs/main').read_text().strip();snapshot=cache/source.name/'snapshots'/sha;snapshot.mkdir(parents=True)
            for path in (source/'snapshots'/sha).rglob('*'):
                if path.is_file():
                    link=snapshot/path.relative_to(source/'snapshots'/sha);link.parent.mkdir(parents=True,exist_ok=True)
                    link.symlink_to(path.resolve())
            refs=cache/source.name/'refs';refs.mkdir();(refs/'main').write_text(sha)
            env=dict(os.environ,VERDICT_SUPPORT_DIR=str(support),HF_HUB_CACHE=str(cache),
                     VERDICT_CATALOG=str(ROOT/'Resources/models.json'),VERDICT_PRELOAD='laya-english',VERDICT_PORT='0')
            with open(root/'stderr.log','w') as errors:
                p=subprocess.Popen([str(BINARY)],env=env,stdout=subprocess.PIPE,stderr=errors,text=True)
                try:
                    port=json.loads(p.stdout.readline())['port'];base=f'http://127.0.0.1:{port}'
                    def post(path,body):
                        req=urllib.request.Request(base+path,data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
                        with urllib.request.urlopen(req,timeout=120) as response:return json.load(response)
                    def status():
                        with urllib.request.urlopen(base+'/status',timeout=20) as response:return json.load(response)
                    questions={'refund':{'type':'noul','instructions':'Does this ask for a refund?'}}
                    def judge(model):
                        answer=post('/judge',{'model':model,'items':['Please refund this.'],'questions':questions})['results'][0]
                        self.assertIn('noul',answer['answers']['refund'])
                    judge('laya-english')
                    baseline=status()['memory']['mlx_active_mb']
                    self.assertGreater(baseline,0)
                    for cycle in range(3):
                        order=('von-1.2','von-1.1') if cycle%2==0 else ('von-1.1','von-1.2')
                        for model in order:
                            post('/load',{'model':model});judge(model)
                        before=status()['memory']['mlx_active_mb']
                        self.assertGreater(before,baseline)
                        for model in reversed(order):
                            post('/unload',{'model':model})
                        result=status();active=result['memory']['mlx_active_mb']
                        print('VON_UNLOAD',cycle,'order',order,'before',before,'after',active,'baseline',baseline,flush=True)
                        self.assertEqual(set(result['models']),{'laya-english'})
                        self.assertEqual(active,baseline,'Von weights remain active after /unload')
                    post('/quit',{})
                finally:
                    if p.poll() is None:p.terminate()
                    p.wait(timeout=15);p.stdout.close()
