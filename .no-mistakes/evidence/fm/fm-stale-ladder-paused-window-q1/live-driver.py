import os, pathlib, subprocess, time, datetime, json, shutil
root=pathlib.Path.cwd(); scratch=root/'.test-live-pause'; ev=pathlib.Path('/Users/king/.no-mistakes/evidence/01M2JKNTE3KHCDZG450382MJEM')
sock=str(scratch/'tmux.sock'); tmux='/opt/homebrew/bin/tmux'
def tm(*args): return subprocess.check_output([tmux,'-S',sock,*args],text=True)
wrap=scratch/'bin'; wrap.mkdir(exist_ok=True)
(wrap/'tmux').write_text('#!/bin/sh\nexec '+tmux+' -S '+sock+' "$@"\n'); (wrap/'tmux').chmod(0o755)
results=[]
try:
 tm('new-session','-d','-s','pausecheck','-n','fm-wait','/bin/sleep 300')
 for name,shape,offset,age,cadence,expect in [('until-future','until {}',120,60,240,'quiet'),('expires-future','[expires={}]',120,60,240,'quiet'),('expires-due','[expires={}]',-30,60,999,'passed'),('expires-far','[expires={}]',31536000,300,240,'beyond'),('open-ended','awaiting release',0,300,240,'awaiting external'),('malformed','[expires=bad]',0,300,240,'awaiting external')]:
  home=scratch/name; state=home/'state'; state.mkdir(parents=True); (home/'config').mkdir(); (home/'config'/'backend').write_text('tmux\n')
  (state/'wait.meta').write_text('window=pausecheck:fm-wait\nkind=secondmate\nbackend=tmux\n')
  iso=datetime.datetime.fromtimestamp(time.time()+offset,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
  f=state/'wait.status'; f.write_text('paused: '+shape.format(iso)+'\n'); os.utime(f,(time.time()-age,time.time()-age))
  env=dict(os.environ,FM_HOME=str(home),FM_STATE_OVERRIDE=str(state),FM_ROOT_OVERRIDE=str(home),PATH=str(wrap)+':'+os.environ['PATH'],FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_PAUSE_RESURFACE_SECS=str(cadence))
  sig=subprocess.check_output(['bash','-c','. bin/fm-classify-lib.sh; f="$1"; printf "v2\\t%s\\t%s@%s" "$(status_observed_signature "$f")" "$(stat -f %z "$f")" "$(_fm_open_decisions_file_ident "$f")"','_',str(f)],env=env,text=True)
  (state/'.seen-wait_status').write_text(sig)
  with (ev/(name+'.log')).open('w') as out:
   p=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=out,stderr=subprocess.STDOUT)
   try: p.wait(timeout=9)
   except subprocess.TimeoutExpired: p.terminate(); p.wait(timeout=5)
  output=(ev/(name+'.log')).read_text(); triage=(state/'.watch-triage.log').read_text() if (state/'.watch-triage.log').exists() else ''
  good=('declared time not reached' in triage and not output.strip()) if expect=='quiet' else expect in output
  good=good and 'possible wedge' not in output
  record={'name':name,'status':f.read_text().strip(),'output':output,'triage':triage,'markers':[x.name for x in state.glob('.*') if 'paused' in x.name or 'wedge' in x.name],'pass':good}
  (ev/(name+'.json')).write_text(json.dumps(record,indent=2)); results.append(record); print(json.dumps(record),flush=True)
finally:
 try: tm('kill-server')
 except Exception: pass
(ev/'results.json').write_text(json.dumps(results,indent=2))
