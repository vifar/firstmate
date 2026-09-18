# Live captain-hold escalation retirement

HOME=/Users/king/.no-mistakes/evidence/01M2SDQSC0XH7TVN0MZKH63SD1/live-home

## escalate first question
$ fm-captain-hold.sh escalate sample-live-escalation --title Live escalated call --repo sample --reason needs captain choice --escalation-file /Users/king/.no-mistakes/evidence/01M2SDQSC0XH7TVN0MZKH63SD1/live-home/q1.json
stdout:
sample-live-escalation
exit=0

## read first prompt
$ fm-captain-hold.sh prompt sample-live-escalation
stdout:
{"context":"Context for First live question?.","evidence":"Measured evidence for First live question?","options":[{"label":"Alpha","value":"alpha"},{"label":"Beta","value":"beta"}],"question":"First live question?","recommendation":"alpha","recommendation_reason":"Alpha preserves the accepted contract.","schema":"fm-captain-escalation.v1","task":"sample-live-escalation"}
exit=0

## answer --release retires spent prompt
$ fm-captain-hold.sh answer sample-live-escalation --decision-file /Users/king/.no-mistakes/evidence/01M2SDQSC0XH7TVN0MZKH63SD1/live-home/answer.txt --release
stdout:
released: sample-live-escalation
exit=0

## spent prompt refuses
$ fm-captain-hold.sh prompt sample-live-escalation
stderr:
fm-captain-hold: task sample-live-escalation has no durable structured escalation
exit=1

## re-escalate same task id after retirement
$ fm-captain-hold.sh escalate sample-live-escalation --reason second choice --escalation-file /Users/king/.no-mistakes/evidence/01M2SDQSC0XH7TVN0MZKH63SD1/live-home/q2.json
stdout:
sample-live-escalation
exit=0

## new prompt is the second question
$ fm-captain-hold.sh prompt sample-live-escalation
stdout:
{"context":"Context for Second live question?.","evidence":"Measured evidence for Second live question?","options":[{"label":"Alpha","value":"alpha"},{"label":"Beta","value":"beta"}],"question":"Second live question?","recommendation":"alpha","recommendation_reason":"Alpha preserves the accepted contract.","schema":"fm-captain-escalation.v1","task":"sample-live-escalation"}
exit=0

## retire-escalation refuses open call
$ fm-captain-hold.sh retire-escalation sample-live-escalation
exit=1

## open prompt still present
$ fm-captain-hold.sh prompt sample-live-escalation
stdout:
{"context":"Context for Second live question?.","evidence":"Measured evidence for Second live question?","options":[{"label":"Alpha","value":"alpha"},{"label":"Beta","value":"beta"}],"question":"Second live question?","recommendation":"alpha","recommendation_reason":"Alpha preserves the accepted contract.","schema":"fm-captain-escalation.v1","task":"sample-live-escalation"}
exit=0

## escalate moot
$ fm-captain-hold.sh escalate sample-live-moot --repo sample --reason ship --escalation-file /Users/king/.no-mistakes/evidence/01M2SDQSC0XH7TVN0MZKH63SD1/live-home/moot.json
stdout:
sample-live-moot
exit=0

## escalate active
$ fm-captain-hold.sh escalate sample-live-active --repo sample --reason order --escalation-file /Users/king/.no-mistakes/evidence/01M2SDQSC0XH7TVN0MZKH63SD1/live-home/active.json
stdout:
sample-live-active
exit=0

## bind board source
$ fm-captain-hold.sh bind live-board
stdout:
bound: live-board -> (any)
exit=0

## file reconcile requests
$ fm-captain-hold.sh reconcile-requests --source-id live-board --source captured board result
stdout:
reconcile: sample-live-moot
reconcile: sample-live-active
reconcile-requests: created=2 skipped=0
exit=0

## reconcile close retires moot prompt
$ fm-captain-hold.sh reconcile close sample-live-moot --evidence-file /Users/king/.no-mistakes/evidence/01M2SDQSC0XH7TVN0MZKH63SD1/live-home/evidence.txt
stdout:
reconciled: sample-live-moot
exit=0

## reconcile note keeps active prompt
$ fm-captain-hold.sh reconcile note sample-live-active --note-file /Users/king/.no-mistakes/evidence/01M2SDQSC0XH7TVN0MZKH63SD1/live-home/note.txt
stdout:
still-open: sample-live-active
exit=0

## active prompt survives note
$ fm-captain-hold.sh prompt sample-live-active
stdout:
{"context":"Context for Which live order?.","evidence":"Measured evidence for Which live order?","options":[{"label":"Alpha","value":"alpha"},{"label":"Beta","value":"beta"}],"question":"Which live order?","recommendation":"alpha","recommendation_reason":"Alpha preserves the accepted contract.","schema":"fm-captain-escalation.v1","task":"sample-live-active"}
exit=0

## sweep retires orphan only
$ fm-captain-hold.sh retire-escalations
stdout:
retired: sample-live-orphan (its task is absent from this home)
retire-escalations: retired=1 kept=2
exit=0

## second sweep silent
$ fm-captain-hold.sh retire-escalations
exit=0

## final answer retires second prompt
$ fm-captain-hold.sh answer sample-live-escalation --decision-file /Users/king/.no-mistakes/evidence/01M2SDQSC0XH7TVN0MZKH63SD1/live-home/answer2.txt
stdout:
answered: sample-live-escalation
exit=0
