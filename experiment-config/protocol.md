# Experiment Protocol — GLM-5.3 vs Fable 5 on one-shot website generation

Version 1.0. This document is the experimental contract. Changing it after runs
have started invalidates cross-run comparability; version it instead.

---

## 1. Role architecture

The `oneshot-websites` skill is an orchestration protocol with three roles, not
a CLI. The experiment exploits that structure: it varies exactly one role.

| Role | Who | Model | Status |
|---|---|---|---|
| **Coordinator** | `kilo run` primary session | `COORDINATOR_MODEL` | **pinned constant** |
| **Lead** | `oneshot-lead` subagent | `GLM_MODEL` *or* `FABLE_MODEL` | **treatment variable** |
| **Critic** | `oneshot-critic` subagent | `CRITIC_MODEL` | **pinned constant** |

**The treatment variable is the lead model, and nothing else.**

The coordinator reserves nothing new, authors nothing, and builds nothing: it
verifies the reserved run, dispatches one fresh lead, and verifies finalization.
The critic is read-only and inspects the real rendered artifact.

Both constants are recorded in every run's `metadata.json` under
`constants.coordinatorModel` and `constants.criticModel`, and the models that
actually served each turn are recorded under
`telemetry.modelsObservedInSession` — so a silent model substitution is
detectable after the fact rather than merely assumed away.

### Why the critic is a third model

`CRITIC_MODEL` defaults to a family that is neither GLM nor Fable. If the critic
were one of the arms, that arm's artifacts would be graded by a sibling of the
model that built them, and any self-preference would land entirely on one side
of the comparison. A third family keeps the grading asymmetry off the treatment.

The binding requirement is that the critic is **identical across both arms**. If
you prefer one of the arms as critic, change `CRITIC_MODEL` once, before any
run, and record the change here. Never change it between arms.

### Harness capability boundary

Verified empirically before this protocol was accepted (see `README.md`):

- Fresh no-history subagent dispatch — **supported**. Verified with a canary
  token held in the coordinator session: the subagent reported `CANARY=NONE`.
- Per-subagent model selection with the coordinator fixed — **supported**.
  Verified by running a coordinator on one model and reading back a different
  model id from the dispatched subagent.
- Recursive delegation (lead → critic) — **supported**, but only after raising
  `subagent_depth`. Kilo's default of `1` silently prevents a subagent from
  launching a subagent, which would have disabled the lead's quality gauntlet
  entirely while appearing to work.
- Autonomous execution with no approval prompts — **supported** via
  `kilo run --auto` plus a pre-approved permission surface, with the interactive
  `question` tool **denied** so no run can block on an absent human.
- Background execution with observable status — **supported** via the harness
  HTTP server (`/api/session`, `/api/session/active`).

Had lead-model selection been unavailable while the coordinator stayed fixed,
the correct outcome would have been to report `UNSUPPORTED_LEAD_MODEL_SELECTION`
and build nothing.

---

## 2. Definition of one-shot

One initial human task prompt → autonomous execution → finished artifact or
failure.

Inside the run the lead may reason, use any tools, run commands, install
dependencies, inspect its own work, spawn descendants to any depth, revise its
implementation, and run its internal quality gauntlet against a fresh critic.
There is no skill-imposed limit on time, tokens, steps, tool calls, iterations,
team size, or recursion depth, and this harness adds none.

"One-shot" is a statement about the **delegation boundary**, not about effort:
one prompt, one owning lead, no human follow-up.

The human must not provide follow-up instructions during a run. The coordinator
is explicitly forbidden from sending the lead guidance, hints, corrections,
examples, or quality opinions of any kind.

### The prompt is sealed before dispatch — and never refined per arm

The skill's default coordinator behaviour is to refine a rough brief into a
fully developed actual prompt. **That behaviour is disabled here.** If each arm's
coordinator refined the prompt independently, the two arms would receive
different bytes and the comparison would be meaningless.

Instead:

1. The operator authors the prompt in `prompts/*.md`, already at the skill's
   prompt-contract standard of completeness.
2. `run-one.sh` reads it as strict UTF-8 (rejecting mojibake, U+FFFD and a BOM)
   and computes its SHA-256.
3. `prepare_run.py` copies those exact bytes to `artifact/PROMPT.md`.
4. The digest of the sealed copy is verified against the source **before**
   anything is dispatched. On mismatch the run is marked failed and nothing runs.
5. The coordinator brief forbids refining, rewriting, reformatting or re-sealing
   those bytes, and forbids consulting the prompt catalogue.
6. After the run, the sealed digest is verified again and recorded in
   `metadata.json` as `prompt.sealIntact`.

Because prompt authoring moved to the operator, **prompt quality is the
operator's responsibility**: a thin prompt produces a thin experiment in both
arms equally.

---

## 3. Failure policy

A failed run is a result, not a problem to fix.

On failure the harness: preserves `agent.log` and `stderr.log`; preserves
partial artifacts; **retains `.tmp/`**; records the honest status; and stops.

**No automatic retry. Ever.** Nothing in this harness re-runs a failed run, and
no script selects a best result from multiple attempts. If you re-run a prompt
after a failure, that is a new, separately recorded run, and you must report
both.

### Status vocabulary

Exactly the skill's own vocabulary. There is no parallel taxonomy.

| Status | Meaning |
|---|---|
| `PLANNED` | reserved, not started |
| `RUNNING` | lead active |
| `OK` | terminal success; `.tmp/` removed; `artifact/index.html` present |
| `PARTIAL` | terminal; incomplete artifact; `.tmp/` retained |
| `BLOCKED` | terminal; genuine blocker; `.tmp/` retained |
| `ERROR` | terminal; failed; `.tmp/` retained |

`status.txt` contains **exactly** the value of `run.json.status` — it is written
by reading that field, never computed independently.

---

## 4. Timeout policy

Per-run wall-clock budget: `RUN_TIMEOUT_SECONDS`, default **4 hours**.

On expiry the process group is terminated (SIGTERM, then SIGKILL after 20s), the
run is recorded as failed, partial artifacts and logs and `.tmp/` are preserved,
and a `timeout_kill` intervention is logged with its trigger. It is never
retried.

**Reconciling this with the skill.** The skill forbids adding a timeout "to
compensate for a harness difference". This timeout is not that: it is an
operator-imposed environment constraint of the kind the skill explicitly leaves
authoritative. Two properties keep it honest:

- It is enforced **outside** the agent, by `run-one.sh`. It is never disclosed
  to the coordinator or the lead, so it cannot function as a budget that shapes
  the lead's behaviour or causes it to truncate its work.
- It is **identical in both arms**, so it cannot advantage either.

macOS ships no `timeout(1)`, so `scripts/lib/common.sh` implements the watchdog
directly over process groups.

---

## 5. Intervention policy

Every intervention is appended to the run's `interventions.jsonl` with a
timestamp, a type, and a trigger, and is copied into `metadata.json`. The same
log shape is produced for both arms.

### Liveness monitoring

The skill requires bounded coordinator liveness checks every 2–5 minutes. In
this harness the `task` tool is **synchronous**: while the lead runs, the
coordinator model cannot act. This is a recorded harness limitation, not
something worked around with a substitute steering channel.

Monitoring therefore runs as an **external observer**
(`scripts/monitor-liveness.sh`), which polls the harness's own HTTP server every
180 seconds — mid-band — and appends a `heartbeat` record carrying session
count, token totals, cost, workspace and artifact file counts, `.tmp/` presence,
and seconds since the last write.

The observer is **content-free by construction**: it has no channel to the
coordinator or the lead and can only read. It therefore cannot leak guidance
into either arm, which is the property the content-free-nudge rule exists to
protect.

### Nudges

Zero. A blocking `task` call has no nudge channel. Consistent with the
experiment rules, **a run that stalls or loops is a failed run** — it is allowed
to run out its wall clock and is then recorded as failed.

### Resume

At most **one** mechanical resume per run, for a session or transport crash
only, replaying only the original dispatch material plus a fixed finalization
reminder. It is off by default, never automatic, and is logged as a `resume`
intervention with its trigger. A resume is never used to rescue a lead that is
merely doing badly.

### Post-freeze rule

After the lead reaches a terminal state the **artifact bytes are frozen**.

The only permitted post-terminal edits are mechanical record-shape
normalizations of the coordinator's own bookkeeping files — `run.json` and
`worker-report.json` — performed by `scripts/normalize-records.py`: status
casing, list-to-string joins for validator-required fields, `{name, key}` object
shapes, null-to-empty-container fills, and filling a *missing* terminal status
on a run whose process is provably over.

That script never reads or writes anything under `artifact/` or `workspace/`,
never changes a status's meaning, never promotes a failed run, never invents
evidence, and never deletes a retained `.tmp/`. Every edit is appended to
`record-normalizations.jsonl` with file, field, before, after, and reason, and
surfaces in `metadata.json`.

---

## 6. Comparison rule

For each prompt: GLM-5.3 gets **one** autonomous run; Fable 5 gets **one**
autonomous run. Both receive the exact same prompt bytes, the same coordinator,
the same critic, the same harness and harness version, the same pinned skill
commit, the same permissions, and the same starting environment.

The two arms run in completely separate run directories and share only the
immutable skill copy and the catalogue index. `run-pair.sh` records the pair's
prompt SHA-256 in `metadata/<pair-id>/pair.json` before dispatch and re-verifies
each arm's sealed `artifact/PROMPT.md` afterwards, printing `MATCH` per arm.

Do not select the best of several attempts. Do not discard an unflattering run.

---

## 7. What is recorded

Per run, inside the skill's own run directory:

| File | Owner | Contents |
|---|---|---|
| `run.json` | skill | identity, status, prompt digest, receipt pointer |
| `worker-report.json` | lead | quality gauntlet, verification, observations |
| `artifact/PROMPT.md` | skill | the sealed prompt, verbatim |
| `artifact/` | lead | the portable static handoff |
| `workspace/` | lead | unrestricted source and build work |
| `.tmp/` | lead | run-local scratch; retained on every non-`OK` run |
| `agent.log` | harness | coordinator stdout (raw JSON event stream) |
| `stderr.log` | harness | coordinator stderr |
| `interventions.jsonl` | harness | every heartbeat, dispatch, timeout, resume |
| `record-normalizations.jsonl` | harness | every mechanical record edit |
| `metadata.json` | harness | derived from the above; never a second copy |
| `status.txt` | harness | exactly `run.json.status` |
| `catalog-validate.txt` | harness | catalogue validator output |

`metadata.json` references the sealed prompt by path and hash rather than
duplicating its bytes, and reads status from `run.json` rather than recomputing
it. Token and cost figures come from harness telemetry; when the harness does
not expose a measurement it is recorded as `null` and **never estimated**.

Across runs, in `metadata/`: `pair.json` per paired comparison and a batch
summary per `run-all.sh` invocation.

---

## 8. Secrets

Real credentials live only in `experiment-config/models.env`, which is
gitignored. `models.example.env` contains placeholders only. No script echoes a
secret value; `verify-environment.sh` reports presence, never content.
