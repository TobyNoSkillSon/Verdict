"""Explicit, destructive-to-its-own-isolated-cache full Von download/delete test.

VERDICT_VON_DOWNLOAD=1 python3 -m unittest -v native.Tests.test_von_download
Runs a fresh pinned 1.2 Hugging Face download via /load and deletes ONLY its
private HF_HUB_CACHE. Never touches /Applications or an existing model cache.
"""
import gzip
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import urllib.request

ROOT=Path(__file__).resolve().parents[2]
BINARY=Path(os.environ.get('VERDICT_HELPER',ROOT/'native/.build/release-helper/verdict-helper'))

@unittest.skipUnless(os.environ.get('VERDICT_VON_DOWNLOAD')=='1','Set VERDICT_VON_DOWNLOAD=1 for a full pinned download/delete')
class VonFreshDownload(unittest.TestCase):
    def test_12_load_answer_delete_disk(self):
        with tempfile.TemporaryDirectory(prefix='verdict-von-fresh-') as base:
            root=Path(base); cache=root/'hub';cache.mkdir();support=root/'support';support.mkdir()
            expected=json.load(gzip.open(ROOT/'native/fixtures/von-1.2-sdk.json.gz'))
            def used_bytes():return sum(path.stat().st_size for path in cache.rglob('*') if path.is_file() and not path.is_symlink())
            before=used_bytes()
            self.assertEqual(before,0)
            env=dict(os.environ,HF_HUB_CACHE=str(cache),VERDICT_SUPPORT_DIR=str(support),
                     VERDICT_CATALOG=str(ROOT/'Resources/models.json'),VERDICT_PRELOAD='',VERDICT_PORT='0')
            env.pop('MLX_ENABLE_TF32',None)
            with open(root/'stderr.log','w') as errors:
                p=subprocess.Popen([str(BINARY)],env=env,stdout=subprocess.PIPE,stderr=errors,text=True)
                try:
                    line=p.stdout.readline();self.assertTrue(line)
                    port=json.loads(line)['port'];base_url=f'http://127.0.0.1:{port}'
                    def post(route,obj,timeout=1800):
                        request=urllib.request.Request(base_url+route,data=json.dumps(obj).encode(),headers={'Content-Type':'application/json'})
                        with urllib.request.urlopen(request,timeout=timeout) as response:return json.load(response)
                    self.assertIn('von-1.2',post('/load',{'model':'von-1.2'})['loaded'])
                    after_load=used_bytes()
                    model=next(x for x in json.loads((ROOT/'Resources/models.json').read_text()) if x['id']=='von-1.2')
                    self.assertEqual(after_load,model['downloadBytes'])
                    snapshot=cache/'models--wfzyx--von'/'snapshots'/model['revision']
                    self.assertTrue((snapshot/'option_marker.pt').is_file())
                    self.assertFalse((snapshot/'von-encoder.safetensors').exists())
                    questions=expected['questions'];items=[x['item'] for x in expected['items'][:2]]
                    response=post('/judge',{'model':'von-1.2','items':items,'questions':questions})['results']
                    for item,result in zip(expected['items'][:2],response):
                        for name,answer in item['batched_answers'].items():
                            for field,value in answer.items():self.assertEqual(result['answers'][name].get(field),value)
                    memory=json.load(urllib.request.urlopen(base_url+'/status'))['memory']
                    post('/unload',{'model':'von-1.2'})
                    deleted=post('/delete',{'model':'von-1.2'})
                    self.assertNotIn('von-1.2',deleted['installed'])
                    after_delete=used_bytes()
                    self.assertEqual(after_delete,0,'/delete must remove downloaded blobs, not just links')
                    print('VON_DOWNLOAD before',before,'after_load',after_load,'after_delete',after_delete,
                          'memory',memory,flush=True)
                    post('/quit',{})
                finally:
                    if p.poll() is None:p.terminate()
                    p.wait(timeout=15)
                    p.stdout.close()
