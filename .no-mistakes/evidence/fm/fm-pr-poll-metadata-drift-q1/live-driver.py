import os, pathlib, subprocess, re, json
root=pathlib.Path.cwd(); home=root/'.phase-test/live2'; state=home/'state'
for d in ['state','config','data']: (home/d).mkdir(parents=True,exist_ok=True)
env=os.environ.copy()
for k in ['FM_STATE_OVERRIDE','FM_ROOT_OVERRIDE','FM_CONFIG_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env.update(FM_HOME=str(home),FM_CHECK_INTERVAL='0',FM_CHECK_TIMEOUT='15',FM_POLL='0.05',FM_HEARTBEAT='999999',FM_SIGNAL_GRACE='0',FM_GUARD_READ_ONLY='1')
log=[]
def run(args,ok=True):
 p=subprocess.run(args,env=env,text=True,capture_output=True,timeout=45)
 log.append('$ '+' '.join(map(str,args))+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)+'\n')
 if ok: assert p.returncode==0,log[-1]
 return p
url='https://github.com/kunchenguid/firstmate/pull/4532'
def arm(id):
 (state/f'{id}.meta').write_text('kind=ship\n')
 run(['bin/fm-pr-check.sh',id,url])
def watch(): return run(['bin/fm-watch.sh'])
def ack():
 p=run(['bin/fm-wake-drain.sh']); m=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',p.stderr)
 assert m,p.stderr
 run(['bin/fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2]])
def stop():
 f=state/'z-stop.check.sh'; f.write_text('#!/usr/bin/env bash\nprintf "control-cycle\\n"\n'); f.chmod(0o700)
 run(['bin/fm-check-register.sh','z-stop'])
def reset():
 (state/'.last-check').unlink(missing_ok=True)
try:
 run(['gh','pr','view',url,'--json','state,headRefOid,url'])
 arm('drift'); reg=(state/'drift.pr-poll-registration').read_bytes()
 with (state/'drift.meta').open('a') as f: f.write('decisions_reviewed=1\ndecision_keys=review-call\nbackend=tmux\nfuture_field=value\n')
 meta=state/'drift.meta'; meta.write_text(re.sub(r'^pr_head=.*$', 'pr_head='+'0'*40, meta.read_text(), flags=re.M))
 assert (state/'drift.pr-poll-registration').read_bytes()==reg
 p=watch(); assert 'drift.check.sh: merged' in p.stdout
 assert all(not (state/('drift.'+s)).exists() for s in ['check.sh','pr-poll','pr-poll-registration','pr-poll-retirement'])
 log.append('Persisted state: drift poll, sidecar, registration, and retirement receipt removed.\n'+(state/'.wake-queue').read_text())
 ack(); stop(); reset(); p=watch(); assert 'control-cycle' in p.stdout and 'merged' not in p.stdout; ack()
 run(['bin/fm-pr-check.sh','drift',url]); reset(); p=watch(); assert 'control-cycle' in p.stdout and 'merged' not in p.stdout; assert not (state/'drift.check.sh').exists(); ack()
 for id,mode in [('foreign','sidecar'),('unauthenticated','registration')]:
  arm(id)
  if mode=='sidecar': (state/f'{id}.pr-poll').write_text('github\nhttps://github.com/kunchenguid/firstmate/pull/1\ngithub.com\nkunchenguid/firstmate\n1\n')
  else: (state/f'{id}.pr-poll-registration').unlink()
  reset(); p=watch(); assert 'control-cycle' in p.stdout and 'merged' not in p.stdout; assert (state/f'{id}.check.sh').exists(); ack()
 log.append('All live assertions passed: metadata drift, retirement, subsequent cycle, rearm absorption, foreign sidecar and missing registration refusal.\n')
finally:
 pathlib.Path('/Users/king/.no-mistakes/evidence/01M2JKNRAX4BS4YK4HP1KYY1Q0/live-cli.txt').write_text('\n'.join(log))
print(log[-1])
