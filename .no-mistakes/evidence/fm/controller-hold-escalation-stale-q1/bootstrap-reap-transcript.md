# Bootstrap stale escalation reap

Seeded `sample-bootstrap-orphan.escalation.json` with no matching backlog row, plus a live open escalated call `sample-bootstrap-live`.

## Direct `retire-escalations` (command bootstrap wraps)

```
retired: sample-bootstrap-orphan (its task is absent from this home)
retire-escalations: retired=1 kept=1
```

- orphan after direct sweep: absent
- live open call after direct sweep: kept

## `bin/fm-bootstrap.sh` local mutating pass

```
BOOTSTRAP_INFO: stale structured captain escalation: retired: sample-bootstrap-orphan (its task is absent from this home)
BOOTSTRAP_INFO: stale structured captain escalation: retire-escalations: retired=1 kept=1
```

- orphan after bootstrap: absent
- live open call after bootstrap: kept
