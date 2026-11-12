#!/usr/bin/env bash
# Gold check for ONE instance, the Apptainer counterpart of TDD-Bench's
#   python3 src/poly_bench_evaluation/run_evaluation.py ... --instance_id_to_run <id> \
#       --skip-existing --evaluate-gold --delete-image
#
#   scripts/run_gold.sh <out_dir> <images_dir> <cache_dir> <instance_id>
#
# 1. pull the instance's frozen image as .sif (SWE-PolyBench GHCR / Multi-SWE-bench), extract caches
# 2. validate offline: ORACLE (base + gold + tests) and BASE (base + tests), RB_REPETITIONS times
# 3. write eval_logs/<instance_id>_result.json  ({"resolved": true/false, ...}, like TDD-Bench)
# 4. with RB_DELETE_IMAGE=1, delete the image and its caches afterwards (like --delete-image);
#    keep them if you will run Stage 2/3 on this instance soon (otherwise they are re-pulled)
# Skips instances that already have a result (like --skip-existing).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
export RB_RUNTIME=${RB_RUNTIME:-frozen}
. "$HERE/lib.sh"
OUT=$(cd "${1:?out_dir}" && pwd); IMAGES=${2:?images_dir}; CACHE=${3:?cache_dir}; ID=${4:?instance_id}
mkdir -p "$IMAGES" "$CACHE" "$OUT/eval_logs"
RES="$OUT/eval_logs/${ID}_result.json"
[[ -f $RES ]] && { echo "exists: $RES"; exit 0; }

TD=$(python3 -I -c '
import json, sys
m = {t["instance_id"]: t["task_dir"] for t in json.load(open(sys.argv[1]))}
print(m.get(sys.argv[2], ""))' "$OUT/manifest.json" "$ID")
[[ -n $TD ]] || die "unknown instance $ID (not in $OUT/manifest.json)"
T="$OUT/$TD"
[[ -f $T/repo.bundle ]] || "$HERE/make_bundles.sh" "$OUT" "$(meta "$T" 'd["repository"]')"

if [[ $RB_RUNTIME == frozen ]]; then
  "$HERE/pull_task_images.sh" "$OUT" "$IMAGES" "$CACHE" "$ID"
else
  "$HERE/warm_dependencies.sh" "$T" "$CACHE" "$IMAGES"
fi
rm -f "$T/validation/verdict.json"
"$HERE/validate_task.sh" "$T" "$IMAGES" "$CACHE" "${RB_REPETITIONS:-3}" >/dev/null || true

python3 -I - "$T/validation/verdict.json" "$RES" "$ID" <<'EOF'
import json, os, sys
vpath, out, iid = sys.argv[1:4]
v = json.load(open(vpath)) if os.path.exists(vpath) else {"verdict": "validation_error"}
res = {"instance_id": iid, "resolved": v["verdict"] == "valid_fail_to_pass", "verdict": v["verdict"],
       "profile": v.get("jdk"), "fail_to_pass": v.get("fail_to_pass", []),
       "pass_to_pass_count": len(v.get("pass_to_pass", [])),
       "oracle_failures": v.get("oracle_failures", []), "stable": v.get("stable")}
json.dump([res], open(out, "w"), indent=2)
print(f"{iid}: {v['verdict']}")
EOF

if [[ ${RB_DELETE_IMAGE:-0} == 1 && $RB_RUNTIME == frozen ]]; then
  rm -f "$IMAGES/tasks/$ID.sif" "$IMAGES/tasks/$ID.sif".*
  rm -rf "$CACHE/tasks/$ID"
fi
