import os,pathlib,subprocess,time,signal,shutil,json
root=pathlib.Path.cwd(); evidence=pathlib.Path('/Users/king/.no-mistakes/evidence/01M2GS94B0V7AA3K2Y9QK8G5M5'); home=root/'.watch-live-test'; home.mkdir(exist_ok=False)
sock=home/'tmux.sock'; env=dict(os.environ,TMUX=f'{sock},0,0',FM_HOME=str(home),FM_POLL='30',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_HOME_SUMMARY_INTERVAL='999999')
state=home/'state'; state.mkdir(); (home/'config').mkdir(); (home/'config/backend').write_text('tmux\n')
logs=[]
def tmux(*args): return subprocess.run(['tmux','-S',str(sock),*args],check=True,capture_output=True,text=True).stdout
def record(name,old=True):
 p=state/name;p.write_text('sentinel\n')
 if old: os.utime(p,(time.time()-1900,)*2)
 return p
def meta(task):
 p=state/(task+'.meta');p.write_text(f'window=gate:fm-{task}\nbackend=tmux\nworktree={home}\nproject={home}\n');return p
def run(label,condition,hook=None):
 out=open(evidence/(label+'.log'),'w'); p=subprocess.Popen(['bash','bin/fm-watch.sh'],env=env,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
 try:
  deadline=time.time()+25
  while time.time()<deadline:
   if hook: hook()
   if condition(): break
   if p.poll() is not None: raise AssertionError(f'{label}: watcher exited {p.returncode}')
   time.sleep(.005)
  else: raise AssertionError(label+': timeout')
  time.sleep(.3)
 finally:
  if p.poll() is None: os.killpg(p.pid,signal.SIGTERM)
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL);p.wait()
  out.close()
 logs.append({'case':label,'records':sorted(p.name for p in state.iterdir() if p.name.startswith(('.hash-','.count-','.stale-','.paused-','.writing-','.wedge-','.churn-')))})
def reset():
 for p in state.iterdir():
  if p.is_dir():shutil.rmtree(p)
  else:p.unlink()
try:
 tmux('new-session','-d','-s','gate','-n','keeper','sleep 300')
 tmux('new-window','-t','gate','-n','fm-live','sleep 300');meta('live')
 markers=['hash','count','stale','stale-since','paused','paused-rechecked','paused-resurfaced','wedge-escalations','churn-since','writing-since','writing-resurfaced']
 for m in markers:record('.'+m+'-gate_fm-dead')
 live=record('.hash-gate_fm-live');fresh=record('.hash-fresh',False)
 durable=record('dead.status');receipt=record('dead.backlog-close')
 run('dead-live-grace',lambda: (state/'.watch-record-sweep-cursor').exists() and not (state/'.writing-since-gate_fm-dead').exists())
 assert live.exists() and fresh.exists() and durable.read_text()=='sentinel\n' and receipt.read_text()=='sentinel\n'
 assert all(not (state/('.'+m+'-gate_fm-dead')).exists() for m in markers)
 reset();meta('closed');tmux('new-window','-t','gate','-n','fm-closed','sleep 300')
 closed=record('.hash-gate_fm-closed');tmux('kill-window','-t','gate:fm-closed')
 run('closed-endpoint',lambda:not closed.exists());assert not closed.exists() and (state/'closed.meta').exists()
 reset()
 for i in range(65):record(f'.hash-dead-{i:02}')
 run('bounded-first-poll',lambda:len(list(state.glob('.hash-dead-*')))==1)
 assert len(list(state.glob('.hash-dead-*')))==1
 run('bounded-next-poll',lambda:not list(state.glob('.hash-dead-*')))
 run('empty-poll',lambda:not (state/'.watch-record-sweep-cursor').exists())
 assert not list(state.glob('.hash-*'))
 reset();meta('live');(state/'live.meta').write_text((state/'live.meta').read_text()+'window=duplicate\n');uncertain=record('.hash-gate_fm-live')
 run('malformed-preserves',lambda:(state/'.watch-record-sweep-cursor').exists());assert uncertain.exists()
 reset();meta('job.a');meta('job_a');tmux('new-window','-t','gate','-n','fm-job.a','sleep 300');collision=record('.hash-gate_fm-job_a')
 run('collision-preserves',lambda:(state/'.watch-record-sweep-cursor').exists());assert collision.exists()
 reset();meta('revived')
 for i in range(20):meta(f'z-extra-{i}')
 # Distinct recognized records for one endpoint force independent inventory reads.
 for m in markers:record('.'+m+'-gate_fm-revived')
 revived=[False]
 def revive():
  if not revived[0] and not (state/'.churn-since-gate_fm-revived').exists():
   tmux('new-window','-t','gate','-n','fm-revived','sleep 300');revived[0]=True
 run('revival-recheck',lambda: (state/'.watch-record-sweep-cursor').exists() and (state/'.watch-record-sweep-cursor').read_text().strip()=='.writing-since-gate_fm-revived',revive)
 assert revived[0] and (state/'.writing-since-gate_fm-revived').exists()
 logs.append({'backend_inventory':tmux('list-windows','-t','gate','-F','#{session_name}:#{window_name}').splitlines()})
 print(json.dumps(logs,indent=2));print('All live assertions passed.')
finally:
 subprocess.run(['tmux','-S',str(sock),'kill-server'],capture_output=True)
 shutil.rmtree(home)
