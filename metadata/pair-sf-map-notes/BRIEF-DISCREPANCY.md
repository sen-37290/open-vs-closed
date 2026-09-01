# sf-map pair: the two arms ran under slightly different briefs

**Recorded:** 2026-09-01T03:36Z

## What differs

The prompt is byte-identical for both arms — sha256
`3580e5b2c8f002533567eeb1d7ec8f1beb5492d198a7853f706cbf188eddf345`, verified
before dispatch and again after each run. That part of the comparison is intact.

The surrounding **run brief** is not identical:

| Arm | Run | Brief |
|---|---|---|
| fable-5 | `2026-08-31-20-03-37-…-fable-5-sf-map` | original |
| glm-5.3 | `2026-08-31-20-36-20-…-glm-5-3-sf-map` | + background-subagent disclosure |

The GLM arm's brief contains one extra paragraph stating that `background: true`
on the task tool does not work in this environment, because `kilo run` exits
when the turn ends and kills the backgrounded subagent.

## Why the arms were not re-run together

The first GLM sf-map attempt (`2026-08-31-20-03-37-…-glm-5-3-sf-map`) failed
purely from that environment limitation, with nothing built. The fix was applied
while the Fable arm was already 23 minutes into a valid run. Re-running both
arms for strict parity would have cost an additional Fable run on a
97,000-token prompt; the operator chose to re-run GLM only.

## How much this weakens the comparison

The added paragraph is an environment disclosure, not design guidance: it says
nothing about how to build the site, what to build, or how much to delegate.

Fable did not use `background: true` in any of its ten task dispatches across
every run to date, so the paragraph addresses a behaviour Fable never exhibited
and is most likely inert for it.

"Most likely inert" is an assumption, not a control. Treat the sf-map pair as a
slightly weaker comparison than the interactive-design pair, where both arms ran
under an identical brief. If the sf-map result is close, do not lean on it.
