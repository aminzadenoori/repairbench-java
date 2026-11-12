#!/usr/bin/env python3
"""Build metrics.json and STATS.md from all evaluated runs.

    python3 summarize.py <out_dir> <runs_dir>

Pass@1 per model = resolved / (tasks whose outcome counts). Missing evaluations
(missing_validation, missing_candidate, eval_no_test_results, not run) stay missing and
are reported separately, never counted as failures. Also sliced per repository, and over
the tasks every model was scored on (so models are compared on the same set).
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path


def main() -> int:
    out, runs = Path(sys.argv[1]), Path(sys.argv[2])
    manifest = {t["instance_id"]: t for t in json.loads((out / "manifest.json").read_text())}
    valid = set()
    for iid, t in manifest.items():
        v = out / t["task_dir"] / "validation" / "verdict.json"
        if v.exists() and json.loads(v.read_text()).get("verdict") == "valid_fail_to_pass":
            valid.add(iid)

    per_model: dict[str, dict[str, dict]] = defaultdict(dict)
    for model_dir in sorted(p for p in runs.iterdir() if p.is_dir()):
        for task_dir in sorted(p for p in model_dir.iterdir() if p.is_dir()):
            r = task_dir / "result.json"
            run = task_dir / "run.json"
            rec = json.loads(r.read_text()) if r.exists() else {"outcome": "not_evaluated", "counts_in_pass_at_1": False}
            if run.exists():
                rec["run_status"] = json.loads(run.read_text()).get("status")
            per_model[model_dir.name][task_dir.name] = rec

    def score(recs: dict, ids) -> dict:
        counted = [i for i in ids if recs.get(i, {}).get("counts_in_pass_at_1")]
        resolved = [i for i in counted if recs[i]["outcome"] == "resolved"]
        outcomes = defaultdict(int)
        for i in ids:
            outcomes[recs.get(i, {}).get("outcome", "not_run")] += 1
        return {"scored": len(counted), "resolved": len(resolved),
                "pass_at_1": round(len(resolved) / len(counted), 4) if counted else None,
                "missing": len(ids) - len(counted), "outcomes": dict(outcomes)}

    common = set(valid)
    for recs in per_model.values():
        common &= {i for i, r in recs.items() if r.get("counts_in_pass_at_1")}

    metrics = {"validated_tasks": len(valid), "common_scored_tasks": len(common), "models": {}}
    for model, recs in per_model.items():
        by_repo = defaultdict(list)
        for i in valid:
            by_repo[manifest[i]["repository"]].append(i)
        metrics["models"][model] = {
            "all_validated": score(recs, sorted(valid)),
            "common_set": score(recs, sorted(common)),
            "by_repository": {repo: score(recs, sorted(ids)) for repo, ids in sorted(by_repo.items())},
        }
    (runs / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")

    lines = ["# Java slice: Pass@1 per model", "",
             f"Validated tasks: {len(valid)}. Scored by every model: {len(common)}.", "",
             "| Model | Pass@1 (all validated) | Resolved / scored | Missing | Pass@1 (common set) |",
             "|---|---:|---:|---:|---:|"]
    for model, m in sorted(metrics["models"].items()):
        a, c = m["all_validated"], m["common_set"]
        fmt = lambda x: "–" if x is None else f"{100 * x:.1f}%"
        lines.append(f"| {model} | {fmt(a['pass_at_1'])} | {a['resolved']} / {a['scored']} | {a['missing']} | {fmt(c['pass_at_1'])} |")
    lines += ["", "Missing evaluations are kept missing and are not counted as failures."]
    (runs / "STATS.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
