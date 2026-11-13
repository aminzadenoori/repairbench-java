#!/usr/bin/env python3
"""Summarize the gold checks, like TDD-Bench's `run_evaluation.py --score-only`.

    python3 score_gold.py <out_dir>

Reads <out>/eval_logs/*_result.json written by run_gold.sh and writes
<out>/eval_logs/scoring_results.json: resolved (valid fail-to-pass), not resolved (with
the reason), and missing (no result yet), plus counts per repository. Also writes
<out>/validated_tasks.txt for Stage 2.
"""
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

out = Path(sys.argv[1])
manifest = {t["instance_id"]: t for t in json.loads((out / "manifest.json").read_text())}
logs = out / "eval_logs"
resolved, not_resolved, reasons = [], [], Counter()
per_repo = defaultdict(Counter)
for f in sorted(logs.glob("*_result.json")):
    r = json.loads(f.read_text())[0]
    iid = r["instance_id"]
    repo = manifest.get(iid, {}).get("repository", "?")
    if r["resolved"]:
        resolved.append(iid); per_repo[repo]["resolved"] += 1
    else:
        not_resolved.append(iid); reasons[r["verdict"]] += 1; per_repo[repo][r["verdict"]] += 1
missing = sorted(set(manifest) - set(resolved) - set(not_resolved))
done = len(resolved) + len(not_resolved)
res = {
    "resolved": {"count": len(resolved), "instance_ids": sorted(resolved)},
    "not_resolved": {"count": len(not_resolved), "by_reason": dict(reasons), "instance_ids": sorted(not_resolved)},
    "missing": {"count": len(missing), "instance_ids": missing},
    "total_in_dataset": len(manifest), "total_processed": done,
    "resolved_rate": f"{100 * len(resolved) / done:.2f}%" if done else "n/a",
    "per_repository": {k: dict(v) for k, v in sorted(per_repo.items())},
}
(logs / "scoring_results.json").write_text(json.dumps(res, indent=2) + "\n")
(out / "validated_tasks.txt").write_text("\n".join(sorted(resolved)) + "\n")
print(f"processed {done}/{len(manifest)}: resolved {len(resolved)} ({res['resolved_rate']}), "
      f"not resolved {len(not_resolved)} {dict(reasons)}, missing {len(missing)}")
for repo, c in res["per_repository"].items():
    print(f"  {repo}: {c}")
