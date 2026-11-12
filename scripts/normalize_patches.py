#!/usr/bin/env python3
"""Check, and where needed repair, gold.patch and test.patch for every task.

Some patches in java.csv lost whitespace on context lines (for example trailing spaces
in Markdown), so a plain `git apply` fails although the change itself is fine. For each
task this script works against a bare mirror of the repository and a temporary git
index at the base commit (no checkout, so it is fast even for trino):

  1. `git apply --cached --check` of gold.patch alone, test.patch alone (as BASE applies
     it) and both together (as ORACLE applies them);
  2. if a patch fails, it is applied with --ignore-whitespace --recount and re-created
     with `git diff --cached --binary`, so the stored patch now applies exactly; the CSV
     version is kept as <name>.orig.patch;
  3. the result goes into metadata.json ("patch_normalization"), and tasks that still
     fail get the review flag "patch_does_not_apply".

Mirrors are created on first use (`git clone --bare --filter=blob:none`, so only the
blobs a patch touches are downloaded). Re-running is safe.

    python3 normalize_patches.py <out_dir> <mirrors_dir> [owner/repo ...]
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def run(args, env=None, input=None, check=False):
    return subprocess.run(args, capture_output=True, text=True, env=env, input=input, check=check)


def ensure_mirror(mirrors: Path, repo: str) -> Path:
    m = mirrors / (repo.replace("/", "__") + ".git")
    if not m.exists():
        print(f"mirroring {repo}", flush=True)
        run(["git", "clone", "--quiet", "--bare", "--filter=blob:none",
             f"https://github.com/{repo}.git", str(m)], check=True)
    return m


def ensure_commit(mirror: Path, sha: str) -> bool:
    if run(["git", "-C", str(mirror), "cat-file", "-e", f"{sha}^{{commit}}"]).returncode == 0:
        return True
    run(["git", "-C", str(mirror), "fetch", "--quiet", "--filter=blob:none", "origin", sha])
    return run(["git", "-C", str(mirror), "cat-file", "-e", f"{sha}^{{commit}}"]).returncode == 0


class Index:
    """A throwaway git index holding the tree of the base commit."""

    def __init__(self, mirror: Path, base: str, tmp: Path):
        self.mirror, self.base = mirror, base
        self.env = dict(os.environ, GIT_INDEX_FILE=str(tmp / "index"))
        run(["git", "-C", str(mirror), "read-tree", base], env=self.env, check=True)

    def apply(self, patch: Path, *extra: str):
        return run(["git", "-C", str(self.mirror), "apply", "--cached", *extra, str(patch)], env=self.env)

    def diff(self) -> bytes:
        # Bytes, not text: some files use CRLF line endings, and text mode would drop the
        # \r characters, producing a patch that no longer applies.
        return subprocess.run(["git", "-C", str(self.mirror), "diff", "--cached", "--binary", self.base],
                              capture_output=True, env=self.env, check=True).stdout


def last_line(s: str) -> str:
    lines = [l for l in s.strip().splitlines() if l.strip()]
    return lines[-1] if lines else "unknown error"


def normalize_one(task: Path, mirror: Path, base: str, tmp: Path) -> dict:
    status = {}
    for name in ("gold.patch", "test.patch"):
        p = task / name
        orig = task / name.replace(".patch", ".orig.patch")
        src = orig if orig.exists() else p           # always start from the CSV version
        idx = Index(mirror, base, tmp)
        if idx.apply(src, "--check").returncode == 0:
            if src is orig:                             # earlier run rewrote it; restore
                shutil.copy2(orig, p)
                orig.unlink()
            status[name] = "exact"
            continue
        r = idx.apply(src, "--ignore-whitespace", "--recount")
        if r.returncode != 0:
            status[name] = "failed: " + last_line(r.stderr)
            continue
        if not orig.exists():
            shutil.copy2(p, orig)
        p.write_bytes(idx.diff())
        status[name] = "regenerated_ignoring_whitespace"
    idx = Index(mirror, base, tmp)
    together = all(idx.apply(task / n).returncode == 0 for n in ("gold.patch", "test.patch"))
    status["gold_and_test_together"] = "ok" if together else "failed"
    return status


def main() -> int:
    out = Path(sys.argv[1]).resolve()
    mirrors = Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    mirrors.mkdir(parents=True, exist_ok=True)
    manifest_path = out / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    counts: dict[str, int] = {}
    for entry in manifest:
        repo = entry["repository"]
        if only and repo not in only:
            continue
        task = out / entry["task_dir"]
        meta_path = task / "metadata.json"
        meta = json.loads(meta_path.read_text())
        mirror = ensure_mirror(mirrors, repo)
        if not ensure_commit(mirror, meta["base_commit"]):
            st = {"gold.patch": "failed: base commit not found", "test.patch": "failed: base commit not found",
                  "gold_and_test_together": "failed"}
        else:
            with tempfile.TemporaryDirectory() as tmpd:
                st = normalize_one(task, mirror, meta["base_commit"], Path(tmpd))
        meta["patch_normalization"] = st
        failed = any(v.startswith("failed") for v in st.values())
        flags = [f for f in meta["review_flags"] if f != "patch_does_not_apply"]
        if failed:
            flags.append("patch_does_not_apply")
        meta["review_flags"] = entry["review_flags"] = flags
        meta_path.write_text(json.dumps(meta, indent=2) + "\n")
        key = "failed" if failed else (
            "regenerated" if "regenerated_ignoring_whitespace" in st.values() else "exact")
        counts[key] = counts.get(key, 0) + 1
        print(f"{entry['instance_id']}: {key}" + ("" if key == "exact" else f" {st}"), flush=True)
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print("summary:", counts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
