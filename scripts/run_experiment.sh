#!/usr/bin/env bash
# Stage 2 + 3 for one model over a list of tasks (resumable: finished tasks are skipped).
#   scripts/run_experiment.sh <model_name> <base_url> <task_list.txt> <out_dir> <images_dir> <cache_dir> <runs_dir>
# task_list.txt: one instance_id per line (e.g. from: jq -r '.[].instance_id' manifest.json).
# Run once per model (each with its own vLLM server), then: python3 scripts/summarize.py <out> <runs>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MODEL=${1:?model}; URL=${2:?base_url}; LIST=${3:?task_list}; OUT=${4:?out_dir}
IMAGES=${5:?images_dir}; CACHE=${6:?cache_dir}; RUNS=${7:?runs_dir}

python3 -I -c '
import json, sys
m = {t["instance_id"]: t["task_dir"] for t in json.load(open(sys.argv[1]))}
for line in open(sys.argv[2]):
    i = line.strip()
    if i and not i.startswith("#"):
        print(m[i] if i in m else "MISSING " + i)' "$OUT/manifest.json" "$LIST" |
while read -r TD; do
  if [[ $TD == MISSING* ]]; then echo "unknown task ${TD#MISSING }" >&2; continue; fi
  ID=$(basename "$TD"); RD="$RUNS/$MODEL/$ID"
  if [[ -f $RD/result.json ]]; then echo "done already: $ID"; continue; fi
  "$HERE/run_agent.sh" "$OUT/$TD" "$MODEL" "$URL" "$IMAGES" "$CACHE" "$RUNS" </dev/null || true
  if [[ -f $RD/candidate.patch || -f $RD/run.json ]]; then
    "$HERE/evaluate_candidate.sh" "$OUT/$TD" "$RD" "$IMAGES" "$CACHE" </dev/null || true
  fi
done
python3 -I "$HERE/summarize.py" "$OUT" "$RUNS"
