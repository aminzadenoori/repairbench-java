#!/usr/bin/env bash
# Stage 2 + 3 for one model over a list of tasks.
#   scripts/run_experiment.sh <model_name> <model_socket> <task_list.txt> <out_dir> <images_dir> <cache_dir> <runs_dir>
# task_list.txt: one instance_id per line (e.g. from: jq -r '.[].instance_id' manifest.json).
# Results go to <runs_dir>/<experiment>/<model>/<task>/, where <experiment> is $RB_EXPERIMENT,
# or a new unique name (scripts/new_id.sh) when that is unset: parallel runs never share a folder.
# The same RB_EXPERIMENT again resumes it (finished tasks are skipped) or adds another model.
# The run settings are kept in <experiment>/<model>/settings.json; resuming with other ones stops.
# Then: python3 scripts/summarize.py <out> <runs_dir>/<experiment>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MODEL=${1:?model}; URL=${2:?model socket (or http URL)}; LIST=${3:?task_list}; OUT=${4:?out_dir}
IMAGES=${5:?images_dir}; CACHE=${6:?cache_dir}; RUNS_ROOT=${7:?runs_dir}
EXP=${RB_EXPERIMENT:-$("$HERE/new_id.sh")}
[[ $EXP =~ ^[A-Za-z0-9._-]+$ ]] || { echo "RB_EXPERIMENT may use only letters, digits, . _ -" >&2; exit 2; }
RUNS=$RUNS_ROOT/$EXP
mkdir -p "$RUNS/$MODEL"
echo "experiment $EXP  ->  $RUNS/$MODEL/"

# Settings that change results: recorded on the first run, and a resume must use the same ones.
python3 -I -c "$(cat <<'PY'
import json, os, sys
path, model, commit = sys.argv[1:4]
e = os.environ
now = {"model": model, "runtime": e.get("RB_RUNTIME", "built"), "history": e.get("RB_HISTORY", "none"),
       "max_steps": e.get("RB_MAX_STEPS", "100"), "max_seconds": e.get("RB_MAX_SECONDS", "3600"),
       "temperature": e.get("RB_TEMPERATURE", "0"), "agent_where": e.get("RB_AGENT_WHERE", "container")}
if os.path.exists(path):
    old = json.load(open(path))
    diff = {k: [old.get(k), v] for k, v in now.items() if old.get(k) != v}
    if diff:
        sys.exit(f"{path} was made with other settings (old, now): {diff}\nuse a new RB_EXPERIMENT name")
    if commit in old.get("commits", []):
        sys.exit(0)
    old["commits"] = old.get("commits", []) + [commit]
    now = old
else:
    now["commits"] = [commit]
tmp = f"{path}.{os.getpid()}"
json.dump(now, open(tmp, "w"), indent=1)
os.replace(tmp, path)
PY
)" "$RUNS/$MODEL/settings.json" "$MODEL" "$(git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null || echo unknown)"

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
echo "experiment $EXP: results in $RUNS/$MODEL/"
