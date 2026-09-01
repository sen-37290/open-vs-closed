#!/usr/bin/env python3
"""Assemble a run's metadata.json.

Metadata is DERIVED from the skill's own records (run.json, worker-report.json)
plus harness telemetry. It never forks the truth into a second copy: status,
classification and prompt provenance are read from run.json, and the sealed
prompt is referenced by path + hash rather than duplicated.

Measurements the harness does not expose are recorded as null. Nothing is
fabricated or estimated.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys


def load_json(path: pathlib.Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def read_jsonl(path: pathlib.Path):
    out = []
    if not path.exists():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except Exception:
            out.append({"unparsed": line})
    return out


def kilo_session_telemetry(session_id: str, kilo_home: str | None = None):
    """Pull real token/cost telemetry, and the model each role actually ran on.

    The per-message modelID is what makes the A/B auditable: it proves the
    coordinator stayed pinned and only the lead varied.
    """
    if not session_id:
        return None
    try:
        env = dict(os.environ)
        if kilo_home and pathlib.Path(kilo_home).is_dir():
            # A sandboxed run keeps its session store inside the run directory,
            # so point the CLI at that HOME rather than the operator's.
            env["HOME"] = kilo_home
            env["XDG_DATA_HOME"] = str(pathlib.Path(kilo_home) / ".local/share")
            env["XDG_CONFIG_HOME"] = str(pathlib.Path(kilo_home) / ".config")
        raw = subprocess.run(
            ["kilo", "export", session_id],
            capture_output=True, text=True, timeout=120, env=env,
        )
        if raw.returncode != 0 or not raw.stdout.strip():
            return None
        data = json.loads(raw.stdout)
    except Exception:
        return None

    info = data.get("info") or {}
    models_seen = {}
    for m in data.get("messages") or []:
        mi = (m or {}).get("info") or {}
        mid, pid = mi.get("modelID"), mi.get("providerID")
        if mid:
            key = f"{pid}/{mid}" if pid else mid
            models_seen[key] = models_seen.get(key, 0) + 1
    return {
        "sessionId": info.get("id"),
        "tokens": info.get("tokens"),
        "cost": info.get("cost"),
        "modelsObservedInSession": models_seen,
        "note": "Token/cost figures cover the primary session. Subagents the "
                "model chose to spawn may have their own sessions; see kilo stats.",
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    for flag in (
        "run-dir", "run-id", "model-alias", "provider", "exact-model-id",
        "prompt-file", "prompt-hash",
        "start-time", "end-time", "wall-clock-seconds", "exit-code",
        "harness-name", "harness-version", "skill-commit", "skill-version",
        "git-commit", "timeout-seconds", "timeout-hit", "kilo-session-file",
        "sandbox",
    ):
        ap.add_argument(f"--{flag}", required=True)
    ap.add_argument("--upstream", default="")
    ap.add_argument("--upstream-ignore", default="")
    ap.add_argument("--materials-sha", default="")
    ap.add_argument("--materials-count", default="0")
    ap.add_argument("--materials-arm-specific", default="no")
    a = ap.parse_args()

    run_dir = pathlib.Path(a.run_dir)
    run_json = load_json(run_dir / "run.json") or {}
    worker = load_json(run_dir / "worker-report.json") or {}

    session_id = ""
    sf = pathlib.Path(a.kilo_session_file)
    if sf.exists():
        session_id = sf.read_text(encoding="utf-8").strip()

    artifact_index = run_dir / "artifact" / "index.html"
    sealed_prompt = run_dir / "artifact" / "PROMPT.md"

    sealed_hash = None
    if sealed_prompt.exists():
        import hashlib
        sealed_hash = hashlib.sha256(sealed_prompt.read_bytes()).hexdigest()

    meta = {
        "schema": "open-vs-closed/metadata/1.0",
        "runId": a.run_id,
        "runDirectory": str(run_dir),

        # ---- the treatment variable: the whole system is this one model ----
        "arm": {
            "modelAlias": a.model_alias,
            "provider": a.provider,
            "exactModelId": a.exact_model_id,
            "upstreamOrder": a.upstream or None,
            "upstreamIgnored": a.upstream_ignore or None,
            "upstreamNote": ("OpenRouter routing preference with fallbacks ENABLED: the run is served by the "
                             "first available upstream in this order, so the provider and quantization that "
                             "actually served it are not guaranteed and are not recorded by the harness"
                             if a.upstream else
                             "upstream not pinned; OpenRouter may route to any provider at any quantization"),
            "scope": "entire run: the session and every subagent it spawned, at every depth",
        },
        # ---- pinned constants, identical across both arms ----
        "constants": {
            "harnessName": a.harness_name,
            "harnessVersion": a.harness_version,
            "oneshotSkillCommit": a.skill_commit,
            "oneshotSkillVersion": a.skill_version,
            "experimentGitCommit": a.git_commit,
            "sandboxed": a.sandbox == "1",
            "isolation": ("container: only this run directory and the read-only skill are visible"
                          if a.sandbox == "1" else
                          "filesystem: sibling runs and experiment docs are readable (isolation instructed, not enforced)"),
        },
        # ---- prompt provenance: referenced, never duplicated ----
        "prompt": {
            "sourceFile": a.prompt_file,
            "sourceSha256": a.prompt_hash,
            "sealedPath": str(sealed_prompt.relative_to(run_dir)) if sealed_prompt.exists() else None,
            "sealedSha256": sealed_hash,
            "sealIntact": (sealed_hash == a.prompt_hash) if sealed_hash else False,
            "materialsCount": int(a.materials_count or 0),
            "materialsCombinedSha256": a.materials_sha or None,
            "materialsArmSpecific": a.materials_arm_specific == "yes",
            "materialsNote": ("this arm received ARM-SPECIFIC materials, so the combined digest "
                              "deliberately differs from other arms: the same source was supplied in a "
                              "form this model can consume. Inputs are equivalent, not identical."
                              if a.materials_arm_specific == "yes" else
                              "binary inputs staged into materials/; the combined digest must match "
                              "across arms for the comparison to be valid"),
        },
        # ---- timing ----
        "timing": {
            "startTime": a.start_time,
            "endTime": a.end_time,
            "wallClockSeconds": int(a.wall_clock_seconds),
            "timeoutSeconds": int(a.timeout_seconds),
            "timeoutHit": a.timeout_hit == "1",
        },
        "exitCode": int(a.exit_code) if str(a.exit_code).lstrip("-").isdigit() else None,

        # ---- status: single source of truth is run.json ----
        "status": run_json.get("status"),
        "statusSource": "run.json.status",
        "workerReportStatus": worker.get("status"),
        "classification": run_json.get("classification"),

        "artifact": {
            "path": "artifact/",
            "entrypointPresent": artifact_index.exists(),
            "tmpRetained": (run_dir / ".tmp").exists(),
        },

        # Did the model actually complete the protocol it was given? Reported,
        # never repaired — a claimed OK that broke the contract stays visible.
        "finalization": load_json(run_dir / ".finalization.json"),

        "interventions": read_jsonl(run_dir / "interventions.jsonl"),
        "recordNormalizations": read_jsonl(run_dir / "record-normalizations.jsonl"),

        "telemetry": kilo_session_telemetry(session_id, str(run_dir / ".kilo-home")) or {
            "sessionId": session_id or None,
            "tokens": None,
            "cost": None,
            "note": "harness telemetry unavailable for this run; not estimated",
        },

        "derivedFrom": ["run.json", "worker-report.json", "interventions.jsonl",
                        "record-normalizations.jsonl", "kilo export"],
    }

    # Single-model integrity check, derived from harness telemetry rather than
    # assumed. If any turn ran on a model other than this arm's, the comparison
    # is contaminated and must be treated as invalid.
    observed = (meta["telemetry"] or {}).get("modelsObservedInSession") or {}
    if observed:
        unexpected = sorted(m for m in observed if m != a.exact_model_id)
        meta["singleModelIntegrity"] = {
            "expectedModel": a.exact_model_id,
            "modelsObserved": sorted(observed),
            "unexpectedModels": unexpected,
            "holds": not unexpected,
            "basis": "per-message modelID from harness telemetry",
        }
    else:
        meta["singleModelIntegrity"] = {
            "expectedModel": a.exact_model_id,
            "modelsObserved": [],
            "unexpectedModels": [],
            "holds": None,
            "basis": "harness telemetry unavailable for this run; not verified, not assumed",
        }

    (run_dir / "metadata.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(json.dumps({"metadata": str(run_dir / "metadata.json"), "status": meta["status"]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
