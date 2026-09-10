import hashlib, json, os, pathlib, subprocess, tempfile
root=pathlib.Path(os.environ.get('ECL_BENCH_OUTPUT', pathlib.Path(__file__).parent)).resolve()
root.mkdir(parents=True, exist_ok=True)
def read(name): return "'cwd "+json.dumps(name)+' fs.read-bytes [] csv.parse-header dict.from-lists '
programs={
 'aggregate':read('metal_bands.csv')+'["Country" "Status"] [["count" "Band ID" \'count] ["total" "Band ID" \'sum]] table.aggregate json.emit io.prin',
 'join':read('metal_bands.csv')+read('all_bands_discography.csv')+'[["Band ID" "Band ID"]] table.inner-join json.emit io.prin',
}
binaries={name:str(pathlib.Path(os.environ['ECL_BENCH_'+name.upper()]).resolve()) for name in ('baseline','updated')}
env=dict(os.environ,ECL_WORKERS='1');env.pop('ECL_PATH',None)
results={}
for name,source in programs.items():
 results[name]={}
 for version,binary in binaries.items():
  with tempfile.TemporaryFile() as output:
   run=subprocess.run([binary,'-e',source],cwd=os.environ['ECL_BENCH_DATA'],env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.PIPE,timeout=180)
   assert run.returncode==0,run.stderr.decode()[:2000]
   size=output.tell();output.seek(0);digest=hashlib.file_digest(output,'sha256').hexdigest()
   results[name][version]=dict(bytes=size,sha256=digest,exit=run.returncode)
   print(name,version,results[name][version],flush=True)
 assert results[name]['baseline']==results[name]['updated']
(root/'result-equivalence.json').write_text(json.dumps(results,indent=2))
