#!/bin/bash
# Smoke test: ONE task with each of the four models, to see that every step runs
# (vLLM starts, leak self-test passes, agent works, patch is scored). Run on the login node.
#
#   scripts/smoke_test_models.sh              submit the jobs (all four models)
#   scripts/smoke_test_models.sh gpt-oss-120b submit only the named model(s)
#   scripts/smoke_test_models.sh --check      print one line per model with the results
#
# Knobs: TASK (default google__gson-2337), TIME (02:00:00), PARTITION (gpuq),
#        RB_MAX_SECONDS (1800) = agent time budget for the test.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh >/dev/null

TASK=${TASK:-google__gson-2337}
TIME=${TIME:-02:00:00}
PARTITION=${PARTITION:-gpuq}
GPU_TYPE=${GPU_TYPE:-h200}             # gpuq: h200, aiq: b200 (the Foundry needs the type)
RB_MAX_SECONDS=${RB_MAX_SECONDS:-1800}
ALL_MODELS="gpt-oss-120b devstral-small glm-4.7-flash qwen3-coder-next"
gpus_for() { python3 -I -c 'import json,sys; print(next(m.get("tensor_parallel",1) for m in json.load(open("configs/models.json"))["models"] if m["name"]==sys.argv[1]))' "$1"; }   # TP = number of GPUs, from configs/models.json

check() {
  printf '%-18s %-9s %-26s %-10s %-12s %s\n' MODEL SELFTEST STOP LOG_LINES PATCH_BYTES OUTCOME
  for M in $ALL_MODELS; do
    python3 -I - "$RUNS/$M/$TASK" "$M" <<'EOF'
import json, os, sys
d, m = sys.argv[1], sys.argv[2]
def j(f, k):
    try: return str(json.load(open(os.path.join(d, f))).get(k, "-"))
    except Exception: return "missing"
def size(f):
    p = os.path.join(d, f)
    return os.path.getsize(p) if os.path.exists(p) else 0
lines = sum(1 for _ in open(os.path.join(d, "trajectory.jsonl"))) if size("trajectory.jsonl") else 0
run = j("run.json", "status")
stop = j("agent.json", "stop_reason") if run in ("ok", "missing") else "run:" + run
print(f"{m:18} {j('selftest.json','passed'):9} {stop:26} {lines:<10} {size('candidate.patch'):<12} {j('result.json','outcome')}")
EOF
  done
  cat <<'EOF'

Good: SELFTEST=True, STOP=finished (or time_budget/max_steps), LOG_LINES in the dozens or more,
OUTCOME=resolved or unresolved. "missing..." or eval_no_test_results means a pipeline problem.
Logs: logs/smoke-<model>-<job>.out, logs/vllm-<model>-<job>.log, logs/agents-<model>-<job>-*.log
EOF
}

if [[ ${1:-} == --check ]]; then check; exit 0; fi

# ---- preflight: fail early with a clear message
fail=0
command -v sbatch >/dev/null || { echo "sbatch not found: module load slurm"; fail=1; }
[[ -s $VLLM_SIF ]] || { echo "no vLLM image at $VLLM_SIF (see README: build environments/vllm.def)"; fail=1; }
V=$(python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["verdict"])
except Exception: print("none")' "$(ls -d "$OUT"/exports/*/"$TASK" 2>/dev/null | head -1)/validation/verdict.json")
[[ $V == valid_fail_to_pass ]] || { echo "$TASK has no valid gold check yet (verdict: $V): scripts/run_gold.sh \"\$OUT\" \"\$IMAGES\" \"\$CACHE\" $TASK"; fail=1; }
[[ -s $IMAGES/tasks/$TASK.sif ]] || { echo "no image for $TASK in $IMAGES/tasks (rerun the gold check)"; fail=1; }

MODELS=${*:-$ALL_MODELS}
for M in $MODELS; do
  [[ " $ALL_MODELS " == *" $M "* ]] || { echo "unknown model $M (one of: $ALL_MODELS)"; fail=1; continue; }
  [[ -s $MODELS_ROOT/$M/config.json ]] || { echo "model $M not downloaded: scripts/download_models.sh $M"; fail=1; }
done
(( fail == 0 )) || exit 1

mkdir -p logs
echo "$TASK" > logs/smoke-task.txt
for M in $MODELS; do
  G=$(gpus_for "$M")
  JOB=$(sbatch --parsable --partition="$PARTITION" --time="$TIME" --gres="gpu:$GPU_TYPE:$G" --job-name="smoke-$M" \
    --export="ALL,MODEL=$M,TP=$G,WORKERS=1,TASKS=$PWD/logs/smoke-task.txt,RB_MAX_SECONDS=$RB_MAX_SECONDS" \
    scripts/slurm_run_model.sh) && echo "submitted $M on $G GPU(s): job $JOB  (log: logs/smoke-$M-$JOB.out)"
done
echo
echo "Watch:  squeue -u \$USER        When all are done:  scripts/smoke_test_models.sh --check"
