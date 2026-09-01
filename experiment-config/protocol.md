# Experiment Protocol — GLM-5.3 vs Fable 5 on one-shot website generation

Version 1.0. This document is the experimental contract. Changing it after runs
have started invalidates cross-run comparability; version it instead.

---

## 1. What is being compared

A run is: **one human prompt handed to one model**, which then works
autonomously until it produces an artifact or fails.

**One model per run.** The initial session and every subagent that model chooses
to spawn — at any depth, in any role — run on the same model. GLM-5.3 runs the
entire system in one arm; Fable 5 runs the entire system in the other.

| | |
|---|---|
| **Treatment variable** | the model, for the whole run |
| **Held constant** | harness, harness version, skill commit, permissions, prompt bytes, timeout, starting environment |

The harness does **not** impose a coordinator, a lead, or a critic, and does not
assign a model to any role. The `oneshot-websites` skill describes a delegation
protocol, and `oneshot-lead` / `oneshot-critic` subagent types are *available*,
but whether the model delegates, how much, and to whom is the model's decision —
and that decision is part of what the experiment measures. Neither subagent type
declares a model, so both inherit the run's single model.

This is enforced mechanically, not by convention:

- `kilo.jsonc` contains no `model` field anywhere — not top-level, not
  `small_model`, not on any agent. `verify-environment.sh` FAILS if one appears.
- `run-one.sh` sets exactly one model per run, via `--model` and
  `KILO_CONFIG_CONTENT`, including `small_model` so even incidental harness
  traffic cannot pull in a second model.
- `metadata.json` records `singleModelIntegrity`, derived from per-message
  `modelID` telemetry: the set of models that actually served the run, and
  whether any unexpected model appeared. A contaminated run is detectable after
  the fact rather than assumed clean.

### Known harness limitation: background subagents

`kilo run` is single-shot and non-interactive. Kilo's `task` tool accepts
`background: true`, which returns immediately and instructs the model to end its
response; the process then exits and kills the backgrounded subagent. The run
fails with nothing built.

This is a property of the environment, not of any model. It is disclosed to both
arms identically in the run brief, in the same category as "no human is
available during this run". Without that disclosure the experiment would partly
be measuring which model happens to avoid an environment-specific trap, rather
than how well it builds a website.

Observed before the fix: every GLM run that passed `background: true` failed
(2/2), every run that did not, succeeded (2/2); Fable never used the parameter
in ten dispatches. Runs that failed this way are environment failures and are
marked with `OPERATOR-INVALIDATION.md` rather than counted as model failures.

### Harness capability boundary

Verified empirically before this protocol was accepted (see `README.md`):

- Fresh no-history subagent dispatch — **supported**. Verified with a canary
  token held in the parent session: the subagent reported `CANARY=NONE`.
- Subagents **inherit** the session model when no model is pinned — verified
  from per-message `modelID` telemetry, which showed a single model across a
  session that dispatched a subagent. This is what makes one-model-per-run
  enforceable rather than merely intended.
- Recursive delegation (subagent spawning subagents) — **supported**, but only after raising
  `subagent_depth`. Kilo's default of `1` silently prevents a subagent from
  launching a subagent, which would have disabled the lead's quality gauntlet
  entirely while appearing to work.
- Autonomous execution with no approval prompts — **supported** via
  `kilo run --auto` plus a pre-approved permission surface, with the interactive
  `question` tool **denied** so no run can block on an absent human.
- Background execution with observable status — **supported** via the harness
  session store (`kilo session list`, `kilo export`). Note that `kilo run` does
  *not* open an HTTP server; only `kilo serve` does, so the observer reads the
  session store rather than an endpoint.

Had no-history subagent dispatch been unavailable, the correct outcome would
have been to report `UNSUPPORTED_NO_FRESH_SUBAGENT` and build nothing.

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

The human must not provide follow-up instructions during a run. Nothing outside
the run may send the model guidance, hints, corrections, examples, or quality
opinions of any kind once it has started.

### The prompt is sealed before dispatch — and never refined per arm

The skill's default behaviour is to refine a rough brief into a fully developed
actual prompt. **That behaviour is disabled here.** If each arm refined the
prompt independently, the two arms would receive different bytes and the
comparison would be meaningless.

Instead:

1. The operator authors the prompt in `prompts/*.md`, already at the skill's
   prompt-contract standard of completeness.
2. `run-one.sh` reads it as strict UTF-8 (rejecting mojibake, U+FFFD and a BOM)
   and computes its SHA-256.
3. `prepare_run.py` copies those exact bytes to `artifact/PROMPT.md`.
4. The digest of the sealed copy is verified against the source **before**
   anything is dispatched. On mismatch the run is marked failed and nothing runs.
5. The run brief forbids refining, rewriting, reformatting or re-sealing
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

### Excluded runs

A run that was disturbed by the operator or the environment — not by the model —
is **excluded rather than repaired or deleted**. Mark it by writing an
`OPERATOR-INVALIDATION.md` into its run directory stating what happened, when,
why it is discarded rather than normalized, and an explicit note that the fault
is not the model's.

`status.txt` still mirrors `run.json.status`, so the status vocabulary stays
single-valued; the presence of the marker file is what excludes the run. Any
analysis must skip runs carrying that marker, and must never count them as model
failures. Deleting such a run is not permitted: removing evidence of an operator
mistake is worse than recording it.

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
  to the model, so it cannot function as a budget that shapes its behaviour or
  causes it to truncate its work.
- It is **identical in both arms**, so it cannot advantage either.

macOS ships no `timeout(1)`, so `scripts/lib/common.sh` implements the watchdog
directly over process groups.

---

## 5. Intervention policy

Every intervention is appended to the run's `interventions.jsonl` with a
timestamp, a type, and a trigger, and is copied into `metadata.json`. The same
log shape is produced for both arms.

### Liveness monitoring

The skill requires bounded liveness checks every 2–5 minutes. In this harness
the `task` tool is **synchronous**: while a dispatched subagent runs, its parent
cannot act. This is a recorded harness limitation, not something worked around
with a substitute steering channel.

Monitoring therefore runs as an **external observer**
(`scripts/monitor-liveness.sh`), which samples every 180 seconds — mid-band —
and appends a `heartbeat` record carrying harness session state, whether this
run's session is visible, workspace and artifact file counts and byte totals,
`.tmp/` presence, log sizes, and seconds since the last write. Seconds-since-last-write
is the real progress signal: a lead that has stopped producing bytes shows up as
a rising number.

The observer is **content-free by construction**: it has no channel into the run at
all and can only read. It therefore cannot leak guidance
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
normalizations of the run's bookkeeping files — `run.json` and
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
autonomous run. Both receive the exact same prompt bytes, the same harness and
harness version, the same pinned skill commit, the same permissions, the same
timeout and the same starting environment. The only difference is the model.

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
| `worker-report.json` | run | quality gauntlet, verification, observations |
| `artifact/PROMPT.md` | skill | the sealed prompt, verbatim |
| `artifact/` | run | the portable static handoff |
| `workspace/` | run | unrestricted source and build work |
| `.tmp/` | run | run-local scratch; retained on every non-`OK` run |
| `agent.log` | harness | run stdout (raw JSON event stream) |
| `stderr.log` | harness | run stderr |
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

## 8. Where the record lives

`runs/` is **local-only and gitignored**. Every run still produces and preserves
the full record on disk exactly as specified — sealed prompt, artifact,
workspace source, gauntlet evidence, logs, metadata, provenance receipts, and
the `.tmp/` retained for every failed run. None of that changes.

What changed is that the record is not repository content. This repository is
the harness; the results are data. A single run reached 23 MB, mostly gauntlet
screenshots, and git is a poor store for that.

Because the record is not backed up by pushing, **back it up deliberately** — an
archive or a copy off the machine — before deleting or re-running anything you
care about. A lost `runs/` directory is a lost experiment.

`metadata/` (small cross-run pair and batch records) and `prompts/` (the sealed
prompts, with their digests) remain tracked, so what was asked and which runs
were paired stays in version control even though the outputs do not.

## 9. Secrets

Real credentials live only in `experiment-config/models.env`, which is
gitignored. `models.example.env` contains placeholders only. No script echoes a
secret value; `verify-environment.sh` reports presence, never content.
