#!/usr/bin/env python3
"""Materialize a prompt from the pinned skill's catalogue into prompts/.

Why prompts come from the catalogue rather than from us
-------------------------------------------------------
This harness disables coordinator-side prompt refinement so both arms receive
byte-identical prompt bytes. Something still has to author a prompt at the
skill's completeness standard. The pinned skill ships 100 such prompts written
by the skill's author, so using them keeps prompt authorship out of the hands of
whoever is running the comparison, and gives every benchmark prompt a citable
provenance id.

The prompt text is written VERBATIM. Nothing is added, trimmed, reformatted or
"improved": the file's sha256 is what both arms will be sealed against.

Usage:
  scripts/materialize-prompt.py --list
  scripts/materialize-prompt.py --list --category "Desktop"
  scripts/materialize-prompt.py --id ow-042
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOGUE = ROOT / ".kilo/skills/oneshot-websites/assets/prompt-catalogue.json"
PROMPTS = ROOT / "prompts"


def load() -> dict:
    return json.loads(CATALOGUE.read_text(encoding="utf-8"))


def slugify(text: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", text.lower())).strip("-")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="List catalogue prompts")
    ap.add_argument("--category", help="Filter the listing by category substring")
    ap.add_argument("--id", help="Catalogue id to materialize, e.g. ow-042")
    a = ap.parse_args()

    data = load()
    prompts = data.get("prompts") or []

    if a.list or not a.id:
        rows = prompts
        if a.category:
            needle = a.category.lower()
            rows = [p for p in rows if needle in str(p.get("category", "")).lower()]
        cats: dict[str, int] = {}
        for p in prompts:
            cats[str(p.get("category"))] = cats.get(str(p.get("category")), 0) + 1
        print(f"{len(prompts)} catalogue prompts, {len(cats)} categories\n")
        for c, n in sorted(cats.items()):
            print(f"  {n:>3}  {c}")
        print()
        for p in rows:
            print(f"  {p.get('id')}  {str(p.get('category'))[:22]:24} {str(p.get('title'))[:46]}")
        if not a.id:
            print("\nMaterialize one with:  scripts/materialize-prompt.py --id <ow-NNN>")
        return 0

    entry = next((p for p in prompts if p.get("id") == a.id), None)
    if entry is None:
        print(f"error: no catalogue prompt with id {a.id!r}", file=sys.stderr)
        return 2

    text = entry.get("prompt")
    if not isinstance(text, str) or not text.strip():
        print(f"error: catalogue entry {a.id} has no prompt text", file=sys.stderr)
        return 2
    if not text.endswith("\n"):
        text += "\n"

    PROMPTS.mkdir(parents=True, exist_ok=True)
    out = PROMPTS / f"{entry['id']}-{slugify(str(entry.get('slug') or entry.get('title')))}.md"
    if out.exists():
        existing = out.read_bytes()
        if existing == text.encode("utf-8"):
            print(f"unchanged: {out.relative_to(ROOT)}")
        else:
            print(f"error: {out.relative_to(ROOT)} exists with different bytes; "
                  f"refusing to overwrite a prompt that runs may already be sealed against",
                  file=sys.stderr)
            return 3
    else:
        out.write_text(text, encoding="utf-8")

    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    prov = PROMPTS / f"{out.stem}.provenance.json"
    prov.write_text(json.dumps({
        "catalogueId": entry.get("id"),
        "slug": entry.get("slug"),
        "title": entry.get("title"),
        "category": entry.get("category"),
        "tags": entry.get("tags"),
        "promptFile": out.name,
        "promptSha256": digest,
        "source": "oneshot-websites assets/prompt-catalogue.json",
        "skillCommit": (ROOT / "experiment-config/SKILL_COMMIT.txt").read_text().strip(),
        "preservation": "verbatim",
    }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    print(f"prompt : {out.relative_to(ROOT)}")
    print(f"sha256 : {digest}")
    print(f"bytes  : {len(out.read_bytes())}")
    print(f"title  : {entry.get('title')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
