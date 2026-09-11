#!/usr/bin/env bash
#
# collect-websites.sh [OUT_DIR]
#
# Gather just the built websites into one browsable directory, for someone who
# wants to look at the results and nothing else. No trajectories, no logs, no
# workspaces, no session stores.
#
#   websites/
#     index.html              a contents page linking every site
#     <prompt>/<arm>/         the artifact exactly as the model shipped it
#
# Keeps the latest completed run per (prompt, arm) and skips pilots and any run
# carrying an OPERATOR-INVALIDATION.md.

set -euo pipefail
EXP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$EXP_ROOT/websites}"
PY="${ONESHOT_WEBSITES_PYTHON:-python3}"

rm -rf "$OUT"; mkdir -p "$OUT"

"$PY" - "$EXP_ROOT" "$OUT" <<'PYEOF'
import hashlib, json, os, re, shutil, sys, pathlib
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
# Matched by run-directory PREFIX, so longest-first: "fable-5" is a prefix of
# "fable-5-1" and would otherwise swallow every 5.1 run.
ARMS = ("glm-5-3-flash", "glm-5-3", "fable-5-1", "fable-5", "kimi-k3", "astra")
PRETTY = {"fable-5-1": "Fable 5.1", "fable-5": "Fable 5", "glm-5-3": "GLM-5.3",
          "glm-5-3-flash": "GLM-5.3-Flash", "kimi-k3": "Kimi K3",
          "astra": "GPT-6 Astra"}

best = {}
for d in sorted((root / "runs").glob("*/")):
    if (d / "OPERATOR-INVALIDATION.md").exists():        continue
    if not (d / "artifact" / "index.html").exists():     continue
    md = d / "metadata.json"
    if not md.exists():                                  continue
    try: m = json.loads(md.read_text())
    except Exception:                                    continue
    if m.get("status") != "OK":                          continue
    name = d.name.split("open-vs-closed-", 1)[-1]
    arm = next((a for a in ARMS if name.startswith(a)), None)
    if not arm:                                          continue
    prompt = name[len(arm) + 1:]
    if prompt == "pilot":                                continue
    best[(prompt, arm)] = (d, m)      # sorted order means last wins = newest

# Which prompt bytes is each task CURRENTLY defined by? A prompt that has been
# rewritten since a run leaves that run's artifact answering a different brief.
# Selecting only on the directory name hid this: the interactive-design section
# once showed GLM's carousel site (built from the superseded prompt) beside two
# cube sites, as though the three were one comparison.
def current_prompt_sha(prompt):
    for cand in (root / "prompts" / f"{prompt}.md",
                 root / "prompts" / prompt / f"{prompt}.md"):
        if cand.exists():
            return hashlib.sha256(cand.read_bytes()).hexdigest()
    return None

rows = []
for (prompt, arm), (d, m) in sorted(best.items()):
    dst = out / prompt / arm
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(d / "artifact", dst)
    (dst / "PROMPT.md").unlink(missing_ok=True)          # the brief, not the site
    html = (dst / "index.html").read_text(errors="replace")[:4000]
    t = re.search(r"<title>([^<]*)</title>", html)
    files = sum(len(fs) for _, _, fs in os.walk(dst))
    size = sum(os.path.getsize(os.path.join(p, x)) for p, _, fs in os.walk(dst) for x in fs)
    tel = m.get("telemetry") or {}
    cur = current_prompt_sha(prompt)
    ran = (m.get("prompt") or {}).get("sealedSha256")
    stale = bool(cur and ran and cur != ran)
    rows.append({"stale": stale,
                 "prompt": prompt, "arm": arm, "armName": PRETTY.get(arm, arm),
                 "title": (t.group(1).strip() if t else ""), "files": files,
                 "kb": round(size / 1024), "wall": m["timing"]["wallClockSeconds"],
                 "cost": tel.get("cost"), "pages": sorted(p.name for p in dst.glob("*.html"))})

# contents page
by_prompt = {}
for r in rows: by_prompt.setdefault(r["prompt"], []).append(r)
parts = ["""<!doctype html><meta charset=utf-8><title>open-vs-closed — results</title>
<style>
:root{color-scheme:light dark}
body{font:15px/1.55 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:960px;margin:3rem auto;padding:0 1.5rem}
h1{font-size:1.6rem;margin-bottom:.2rem} .sub{opacity:.65;margin-bottom:2.5rem}
h2{font-size:1.05rem;margin:2.2rem 0 .6rem;padding-bottom:.35rem;border-bottom:1px solid color-mix(in srgb,currentColor 18%,transparent)}
table{border-collapse:collapse;width:100%} td,th{padding:.5rem .6rem;text-align:left;vertical-align:top}
th{font-weight:600;font-size:.78rem;text-transform:uppercase;letter-spacing:.04em;opacity:.6}
tr+tr td{border-top:1px solid color-mix(in srgb,currentColor 10%,transparent)}
a{color:inherit} .t{opacity:.7;font-size:.9rem} .n{font-variant-numeric:tabular-nums;opacity:.65;white-space:nowrap}
code{background:color-mix(in srgb,currentColor 8%,transparent);padding:.1rem .35rem;border-radius:3px;font-size:.85em}
.stale{display:inline-block;margin-left:.45rem;padding:.05rem .4rem;border-radius:3px;font-size:.7rem;font-weight:600;
letter-spacing:.03em;background:#b4540022;color:#b45400;border:1px solid #b4540055}
@media (prefers-color-scheme:dark){.stale{background:#f5a97f22;color:#f5a97f;border-color:#f5a97f55}}
.warn{margin:.5rem 0 0;font-size:.82rem;opacity:.75}
</style>
<h1>open-vs-closed — built websites</h1>
<div class=sub>One prompt, one model, one autonomous run each. Open a folder's <code>index.html</code>.</div>"""]
for prompt in sorted(by_prompt):
    parts.append(f"<h2>{prompt}</h2><table><tr><th>Model<th>Site<th>Pages<th>Size<th>Time<th>Cost")
    for r in sorted(by_prompt[prompt], key=lambda x: x["armName"]):
        cost = f"${r['cost']:.2f}" if r["cost"] else "—"
        badge = ("<span class=stale title='built from a superseded version of this prompt'>OLD PROMPT</span>"
                 if r["stale"] else "")
        pages = ", ".join(p.replace(".html", "") for p in r["pages"][:6]) or "index"
        parts.append(
            f"<tr><td><a href='{r['prompt']}/{r['arm']}/index.html'><b>{r['armName']}</b></a>{badge}"
            f"<td class=t><a href='{r['prompt']}/{r['arm']}/index.html'>{r['title'] or 'index.html'}</a>"
            f"<td class=t>{pages}<td class=n>{r['kb']} KB<td class=n>{r['wall']//60} min<td class=n>{cost}")
    parts.append("</table>")
    if any(r["stale"] for r in by_prompt[prompt]):
        parts.append("<p class=warn>&#9888; Entries marked <b>OLD PROMPT</b> were built from a superseded "
                     "version of this brief and are <b>not comparable</b> with the others above.</p>")
(out / "index.html").write_text("\n".join(parts), encoding="utf-8")

print(f"  {len(rows)} sites -> {out}")
for r in rows:
    print(f"    {r['prompt']}/{r['arm']}  ({r['files']} files, {r['kb']} KB)"
          + ("   <-- OLD PROMPT, not comparable" if r["stale"] else ""))
PYEOF
echo
echo "  browse: open $OUT/index.html"
