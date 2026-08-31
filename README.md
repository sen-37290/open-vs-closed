# open-vs-closed

A reproducible A/B harness for comparing **GLM-5.3** and **Fable 5** on
one-prompt autonomous website generation, using the
[`jpcaparas/skills`](https://github.com/jpcaparas/skills) `oneshot-websites`
protocol.

One prompt in. One autonomous agent run. One artifact, or one preserved failure.

## The one idea

`oneshot-websites` is an orchestration protocol with three roles — coordinator,
lead, critic — not a CLI you invoke once. This harness varies **exactly one of
them**:

```
coordinator  (pinned constant)  ──dispatches──▶  LEAD  ◀── the treatment variable
                                                  │         GLM-5.3  or  Fable 5
                                                  └──dispatches──▶  critic (pinned constant)
```

Everything else — harness, harness version, skill commit, permissions, prompt
bytes, starting environment, coordinator model, critic model — is held identical
across both arms and recorded in every run's metadata.

Read [`experiment-config/protocol.md`](experiment-config/protocol.md) before
running anything. It is the experimental contract.

## Quick start

```bash
brew install uv                     # manages the Python the skill helpers need
npm install -g @kilocode/cli@7.5.6  # the coding-agent harness

uv python install                   # installs the pinned interpreter (3.13)

$EDITOR experiment-config/models.env   # set OPENROUTER_API_KEY (file is gitignored)

./scripts/verify-environment.sh        # must be all-PASS
./scripts/run-one.sh glm-5.3 prompts/pilot.md
```

`experiment-config/models.env` already exists with every default filled in; the
only value you must supply is `OPENROUTER_API_KEY`. It is gitignored, and
`models.example.env` is the committed placeholder copy.

Python is managed by **uv**: `pyproject.toml` declares `requires-python >=3.11`
and `.python-version` pins 3.13, so the experiment never depends on whichever
`python3` happens to be first on PATH (this machine's default is 3.9, which the
skill helpers reject). The pinned skill's helpers import only the standard
library, so there are no runtime dependencies to install.

## Layout

```
open-vs-closed/
├── kilo.jsonc                      pinned harness config — the constant half
├── .kilo/skills/oneshot-websites/  pinned skill (harness discovery path)
├── skills -> .kilo/skills          convenience symlink
├── experiment-config/
│   ├── protocol.md                 the experimental contract
│   ├── models.example.env          placeholders only, never real keys
│   ├── coordinator-brief.template.md
│   └── SKILL_COMMIT.txt            pinned upstream commit SHA
├── prompts/pilot.md                harness-verification prompt only
├── scripts/
│   ├── run-one.sh                  one arm, one prompt, one run
│   ├── run-pair.sh                 both arms, identical bytes, in parallel
│   ├── run-all.sh                  batch (gated until the pilot passes)
│   ├── verify-environment.sh       PASS/FAIL preflight
│   ├── monitor-liveness.sh         external content-free liveness observer
│   ├── normalize-records.py        mechanical record-shape fixes, logged
│   ├── assemble_metadata.py        derives metadata.json from the real records
│   └── lib/common.sh               shared helpers, portable timeout
├── runs/                           the experimental record — NOT gitignored
└── metadata/                       cross-run pair and batch records
```

`runs/<timestamp-slug>/` **is** the skill's own run directory, created by
`prepare_run.py`. It already contains `artifact/`, `workspace/`, `run.json`,
`worker-report.json` and — while active or failed — `.tmp/`. This harness adds
`agent.log`, `stderr.log`, `metadata.json`, `status.txt`,
`interventions.jsonl` and `record-normalizations.jsonl` **beside** those, inside
the same directory. There is no parallel per-run layout.

## How the skill is loaded

Kilo discovers skills at `{skill,skills}/<name>/SKILL.md` inside a `.kilo/`
config directory, walking up from the working directory to the git worktree
root. The pinned copy therefore lives at
`.kilo/skills/oneshot-websites/`, and because this directory is its own git
repository, that walk stops here and cannot pick up a parent project's config.

The skill is vendored **unmodified**. `experiment-config/SKILL_COMMIT.txt`
records the upstream commit; `verify-environment.sh` runs the author's own
`validate.py` and `test_skill.py` against the pinned copy on every preflight.

## How the arms are separated

`kilo.jsonc` is identical for every run. `run-one.sh` overrides **only** the
lead's model, per run, through the `KILO_CONFIG_CONTENT` environment variable —
never by editing a file. Nothing else about the harness differs between arms.

`metadata.json` records both the requested model and, from harness telemetry,
the models that actually served each turn, so a silent substitution is
detectable rather than assumed away.

## Verified harness capabilities

Each was probed on this machine before the harness was built, not assumed:

| Capability | Result | How it was verified |
|---|---|---|
| No-history subagent dispatch | supported | canary token in the coordinator session; subagent reported `CANARY=NONE` |
| Per-subagent model selection, coordinator fixed | supported | coordinator on one model read back a different model id from its subagent |
| Recursive delegation (lead → critic) | supported | grandchild subagent wrote a file; **requires** raising `subagent_depth` from its default of `1` |
| Autonomous, no approval prompts | supported | `--auto` + pre-approved permissions; `question` denied |
| Background with observable status | supported | harness session store (`kilo session list`); note `kilo run` opens no HTTP server, only `kilo serve` does |
| Both arms on one provider | supported | `z-ai/glm-5.3` and `anthropic/claude-fable-5` both visible via OpenRouter |

The `subagent_depth` default is the dangerous one: at `1`, the lead cannot spawn
a critic, so the quality gauntlet silently does not happen while the run still
reports success.

## Rules this harness enforces

- No automatic retry, ever. Failures are preserved with partial artifacts, logs
  and a retained `.tmp/`.
- No best-of selection.
- No human follow-up during a run; the coordinator is forbidden from sending the
  lead guidance.
- No manual edits to generated artifacts. After a terminal state artifact bytes
  are frozen; only the coordinator's own bookkeeping records may be
  shape-normalized, and every such edit is logged.
- Identical prompt bytes per pair, digest-verified before dispatch and again
  after the run.
- Secrets never enter a committed file.

## Commands

```bash
./scripts/verify-environment.sh                    # preflight
./scripts/run-one.sh  glm-5.3 prompts/pilot.md     # one GLM run
./scripts/run-one.sh  fable-5 prompts/pilot.md     # one Fable run
./scripts/run-pair.sh prompts/pilot.md             # both arms, identical bytes

I_HAVE_FINISHED_THE_PILOT=1 ./scripts/run-all.sh   # the real benchmark
```

`run-all.sh` is deliberately gated so the real benchmark cannot start by
accident.

## Requirements

macOS or Linux, uv, Kilo CLI 7.5.6, git, curl, Python ≥ 3.11 for the skill helpers
(auto-discovered; override with `ONESHOT_WEBSITES_PYTHON`), and a keep-awake
mechanism (`caffeinate` on macOS) so a host sleep cannot corrupt wall-clock and
liveness measurements mid-run.
