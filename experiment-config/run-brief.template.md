# Run Brief — open-vs-closed

You have been given one website-generation task. Complete it autonomously.

Use the `oneshot-websites` skill as the protocol for this work. Read it now:
`@@SKILL_DIR@@/SKILL.md`, and `@@SKILL_DIR@@/references/execution-protocol.md`.

How you organise the work is your decision. You may do it yourself, or delegate
to fresh subagents and give them roles, and they may delegate further. Two
subagent types are available if you want them — `oneshot-lead` and
`oneshot-critic` — and you may create others. Nothing here dictates how many
you spawn, in what order, or whether you use any at all.

Everything you spawn runs on the same model as you. There is no second model
available in this run and none is needed.

The paragraphs below are constraints from the operator. They are authoritative
and override any conflicting default in the skill.

## The run is already reserved — do not reserve another

`scripts/prepare_run.py` has ALREADY been executed by the operator's harness.

- Run directory: `@@RUN_DIR@@`
- Run ID: `@@RUN_ID@@`
- Model for this run: `@@RUN_MODEL@@`
- Prompt (already sealed): `@@RUN_DIR@@/artifact/PROMPT.md`
- Prompt SHA-256: `@@PROMPT_SHA256@@`
- Run-local temporary storage: `@@RUN_DIR@@/.tmp/`
- Workspace: `@@RUN_DIR@@/workspace/`
- Artifact: `@@RUN_DIR@@/artifact/`
- Temporary cleanup helper: `@@SKILL_DIR@@/scripts/cleanup_run_tmp.py`
- Helper interpreter: `@@PY@@`

Do NOT run `prepare_run.py`. Do NOT create another run directory. Treat this as
a verified continuation of an already-reserved run, exactly as the skill's
"Recover the Current Run or Reserve a New One" step allows. Verify identity
first: read `@@RUN_DIR@@/run.json` and confirm the digest above matches
`run.json.prompt.sha256`.

## The prompt is SEALED — do not refine it

This is the most important constraint.

Both arms of this comparison must receive byte-identical prompt bytes. The
prompt at `@@RUN_DIR@@/artifact/PROMPT.md` is the final task. It was authored by
the operator and sealed before you started.

You MUST NOT refine, rewrite, expand, compress, reformat, re-seal, translate,
or append to those bytes, and you must not consult the prompt catalogue or
`list_prompts.py`. Skip the skill's prompt-authoring step entirely. Read
`artifact/PROMPT.md` and treat its exact bytes as the task. If you delegate,
pass those exact bytes as the actual prompt. Any edit to that file invalidates
the experiment and is detected by a post-run digest check.

## Directional-control contract (operational; NOT part of the task prompt)

@@DIRECTIONAL_CONTROL_GUIDANCE@@

## Finalization

Bring the run to a terminal state and record it honestly in `run.json` and
`worker-report.json`:

- `OK` requires `artifact/index.html` to exist and `.tmp/` to have been removed
  by the cleanup helper.
- `PARTIAL`, `BLOCKED` and `ERROR` all RETAIN `.tmp/`. Never delete it for a
  non-`OK` run.
- The SHA-256 of `artifact/PROMPT.md` must still equal `@@PROMPT_SHA256@@`.

If you cannot finish, record the honest status and stop. Do not start over, do
not re-run the task, and do not paper over a failure. A failed run is a
preserved result of this experiment, not a problem to fix.

Do not build the catalogue index and do not run `validate_catalog.py`; the
operator's harness owns those steps so they happen identically for both arms.

## Absolute boundaries

- Local only. Never upload, deploy, publish, push, or claim anything remote.
- Never touch any other run directory under `@@RUNS_ROOT@@`. No sibling
  comparison of any kind.
- Never ask the operator a question. No human is available during this run.

Begin.
