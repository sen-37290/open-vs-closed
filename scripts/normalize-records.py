#!/usr/bin/env python3
"""Mechanical, logged record-shape normalization — bookkeeping files only.

POST-FREEZE RULE
================
After a lead reaches a terminal state the ARTIFACT BYTES ARE FROZEN. This
script never reads, writes, touches or even stats anything under artifact/ or
workspace/. It only repairs the *shape* of the coordinator's own bookkeeping
records, run.json and worker-report.json, so the skill's catalogue validator can
read them.

It is allowed to:
  - coerce a status string to the skill's vocabulary casing (ok -> OK)
  - join a list-valued field that the validator requires as a string
  - wrap a bare string in the {name, key} object shape the schema requires
  - fill a MISSING terminal status on a run whose process is provably over
  - fill a missing required container with an empty container of the right type

It is NOT allowed to:
  - change any status value's meaning (OK never becomes PARTIAL, and a failed
    run is never promoted)
  - invent evidence, verification entries, gauntlet records or timings
  - delete a retained .tmp/
  - touch artifact/ or workspace/

Every edit is appended to the run's record-normalizations.jsonl with the file,
the field path, the before and after values, and the reason.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from datetime import datetime, timezone

TERMINAL = ("OK", "PARTIAL", "BLOCKED", "ERROR")
VALID = ("PLANNED", "RUNNING") + TERMINAL


class Normalizer:
    def __init__(self, run_dir: pathlib.Path, log_path: pathlib.Path):
        self.run_dir = run_dir
        self.log_path = log_path
        self.edits: list[dict] = []

    def log(self, file: str, field: str, before, after, reason: str) -> None:
        self.edits.append({
            "time": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "file": file,
            "field": field,
            "before": before,
            "after": after,
            "reason": reason,
            "contentChanged": False,
        })

    # -- individual mechanical fixes -----------------------------------------
    def fix_status(self, doc: dict, fname: str, timeout_hit: bool) -> dict:
        raw = doc.get("status")

        if isinstance(raw, str) and raw.upper() in VALID and raw != raw.upper():
            self.log(fname, "status", raw, raw.upper(), "status vocabulary is uppercase")
            doc["status"] = raw.upper()
            raw = doc["status"]

        # A run whose coordinator process is over but whose record still says
        # PLANNED/RUNNING never finished. Recording that as ERROR is not a
        # promotion: it is the honest terminal value for an unfinished run.
        if raw in (None, "", "PLANNED", "RUNNING"):
            reason = ("run terminated by the wall-clock timeout without reaching a "
                      "terminal status" if timeout_hit else
                      "coordinator process exited without writing a terminal status")
            self.log(fname, "status", raw, "ERROR", reason)
            doc["status"] = "ERROR"

        elif raw not in VALID:
            self.log(fname, "status", raw, "ERROR",
                     f"status {raw!r} is outside the skill vocabulary {VALID}")
            doc["status"] = "ERROR"
        return doc

    def fix_identity(self, doc: dict, fname: str) -> dict:
        ident = doc.get("identity")
        if not isinstance(ident, dict):
            return doc
        for key in ("model", "harness", "experiment"):
            val = ident.get(key)
            if isinstance(val, str):
                self.log(fname, f"identity.{key}", val, {"name": val, "key": val},
                         "schema requires the {name, key} object shape")
                ident[key] = {"name": val, "key": val}
        return doc

    def fix_string_joins(self, doc: dict, fname: str) -> dict:
        for field in ("summary", "notes", "blocker", "conclusion"):
            val = doc.get(field)
            if isinstance(val, list) and all(isinstance(x, str) for x in val):
                joined = " ".join(val)
                self.log(fname, field, val, joined,
                         "validator requires a string; list joined without changing content")
                doc[field] = joined
        return doc

    def fix_containers(self, doc: dict, fname: str) -> dict:
        for field, empty in (("verification", []), ("observations", {})):
            if field in doc and doc[field] is None:
                self.log(fname, field, None, empty,
                         "required container was null; replaced with an empty container")
                doc[field] = empty
        return doc

    # -- driver ---------------------------------------------------------------
    def run(self, timeout_hit: bool) -> int:
        for fname in ("run.json", "worker-report.json"):
            path = self.run_dir / fname
            if not path.exists():
                self.log(fname, "<file>", None, "absent",
                         "record missing entirely; left absent (never fabricated)")
                continue
            try:
                original = path.read_text(encoding="utf-8")
                doc = json.loads(original)
            except Exception as exc:
                self.log(fname, "<file>", "unparseable", "unchanged",
                         f"could not parse as JSON ({exc}); left untouched")
                continue
            if not isinstance(doc, dict):
                continue

            before = json.dumps(doc, sort_keys=True)
            doc = self.fix_status(doc, fname, timeout_hit)
            doc = self.fix_identity(doc, fname)
            doc = self.fix_string_joins(doc, fname)
            doc = self.fix_containers(doc, fname)

            if json.dumps(doc, sort_keys=True) != before:
                path.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n",
                                encoding="utf-8")

        if self.edits:
            with self.log_path.open("a", encoding="utf-8") as fh:
                for e in self.edits:
                    fh.write(json.dumps(e, ensure_ascii=False) + "\n")
        print(json.dumps({"normalizations": len(self.edits), "log": str(self.log_path)}))
        return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--run-dir", required=True, type=pathlib.Path)
    ap.add_argument("--log", required=True, type=pathlib.Path)
    ap.add_argument("--timeout-hit", default="0")
    a = ap.parse_args()

    if not a.run_dir.is_dir():
        print(f"error: run directory not found: {a.run_dir}", file=sys.stderr)
        return 2
    return Normalizer(a.run_dir, a.log).run(a.timeout_hit == "1")


if __name__ == "__main__":
    sys.exit(main())
