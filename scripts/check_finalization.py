#!/usr/bin/env python3
"""Verify the skill's finalization contract for one run — report only.

This NEVER repairs anything and never rewrites a status. A model that claimed
`OK` while breaking the contract stays visible as exactly that, because whether
a model finishes the protocol it agreed to is part of what the experiment
measures. Repairing it here would delete the finding.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

TERMINAL = {"OK", "PARTIAL", "BLOCKED", "ERROR"}
RETAINS_TMP = {"PARTIAL", "BLOCKED", "ERROR"}


def status_of(run: pathlib.Path, name: str):
    try:
        return json.loads((run / name).read_text(encoding="utf-8")).get("status")
    except Exception:
        return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run-dir", required=True, type=pathlib.Path)
    ap.add_argument("--expected-digest", required=True)
    a = ap.parse_args()
    run = a.run_dir

    run_status = status_of(run, "run.json")
    worker_status = status_of(run, "worker-report.json")
    tmp_present = (run / ".tmp").exists()
    entrypoint = (run / "artifact" / "index.html").exists()

    sealed = run / "artifact" / "PROMPT.md"
    digest = hashlib.sha256(sealed.read_bytes()).hexdigest() if sealed.exists() else None

    violations: list[str] = []
    if run_status not in TERMINAL:
        violations.append(f"run.json status {run_status!r} is not terminal")
    if worker_status not in TERMINAL:
        violations.append(f"worker-report.json status {worker_status!r} is not terminal")
    if run_status != worker_status:
        violations.append(
            f"status records disagree: run.json={run_status!r} worker-report={worker_status!r}"
        )
    if run_status == "OK":
        if tmp_present:
            violations.append("status is OK but .tmp/ was not removed (the skill requires it absent)")
        if not entrypoint:
            violations.append("status is OK but artifact/index.html is missing")
    if run_status in RETAINS_TMP and not tmp_present:
        violations.append(f"status is {run_status} but .tmp/ was not retained")
    if digest is None:
        violations.append("sealed artifact/PROMPT.md is missing")
    elif digest != a.expected_digest:
        violations.append(f"sealed prompt digest changed: {digest} != {a.expected_digest}")

    print(json.dumps({
        "runStatus": run_status,
        "workerStatus": worker_status,
        "tmpPresent": tmp_present,
        "entrypointPresent": entrypoint,
        "sealedDigestMatches": digest == a.expected_digest,
        "contractViolations": violations,
        "contractHolds": not violations,
        "note": "reported, never repaired; the model's status is left exactly as it wrote it",
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
