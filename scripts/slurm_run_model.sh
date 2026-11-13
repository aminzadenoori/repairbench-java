#!/bin/bash
# Stages 2+3 for ONE model as a Slurm job on the Foundry GPU nodes:
# start vLLM on the allocated GPUs, wait until it answers, run agent + evaluation over a
# task list, stop vLLM. Resumable: finished tasks are skipped if the job is resubmitted.
#
#   sbatch --export=ALL,MODEL=gpt-oss-120b,TP=1 --gres=gpu:h200:1 scripts/slurm_run_model.sh
#   sbatch --export=ALL,MODEL=qwen3-coder-next --gres=gpu:h200:2 scripts/slurm_run_model.sh
# TP (number of GPUs) defaults to the model's "tensor_parallel" in configs/models.json;
# --gres must ask for that many GPUs.
# Optional: TASKS=<file with instance ids> (default: out/validated_tasks.txt),
#           WORKERS=<agents in parallel against the one vLLM server> (default 4)
#
#SBATCH --job-name=rb-model
#SBATCH --partition=gpuq
#SBATCH --gres=gpu:h200:1         # the Foundry needs the GPU type (aiq partition: gpu:b200:N)
#SBATCH --cpus-per-task=32
#SBATCH --mem=256G
#SBATCH --time=24:00:00
#SBATCH --output=logs/%x-%j.out
set -euo pipefail

command -v apptainer >/dev/null || { echo "apptainer not found on $(hostname)"; exit 1; }   # on the PATH, no module needed

cd "${SLURM_SUBMIT_DIR:-$HOME/repairbench-java}"
mkdir -p logs
source scripts/env.sh
export APPTAINER_TMPDIR=/tmp/$USER/apptainer-tmp && mkdir -p "$APPTAINER_TMPDIR"

MODEL=${MODEL:?set MODEL, e.g. --export=ALL,MODEL=gpt-oss-120b}
TP=${TP:-$(python3 -I -c 'import json,sys; print(next(m.get("tensor_parallel",1) for m in json.load(open("configs/models.json"))["models"] if m["name"]==sys.argv[1]))' "$MODEL")}
TASKS=${TASKS:-$OUT/validated_tasks.txt}
# Both containers run on THIS node, both with no network: vLLM answers on a socket file on
# local disk; every agent container mounts that folder and reaches it through its own
# forwarder at 127.0.0.1:8000 (see agent/in_container.sh).
JOBTAG=${SLURM_JOB_ID:-local$$}
SOCK=/tmp/$USER-rb-$JOBTAG/vllm.sock
VINST=rbvllm_$JOBTAG
VLOG=logs/vllm-$MODEL-$JOBTAG.log

echo "node $(hostname)  model $MODEL  tp $TP  socket $SOCK  tasks $(grep -c . "$TASKS")"
nvidia-smi -L

scripts/serve_model.sh "$MODEL" "$SOCK" "$TP" "$VINST" >"$VLOG" 2>&1 &
VLLM=$!
trap 'kill $VLLM 2>/dev/null || true; apptainer instance stop "$VINST" >/dev/null 2>&1 || true; rm -rf "$(dirname "$SOCK")"' EXIT

ready() { curl -sf --unix-socket "$SOCK" http://localhost/v1/models >/dev/null 2>&1; }
for _ in $(seq 1 120); do                      # up to 30 minutes to load the weights
  ready && break
  kill -0 $VLLM 2>/dev/null || { echo "vLLM exited:"; tail -40 "$VLOG"; exit 1; }
  sleep 15
done
ready || { echo "vLLM not ready after 30 min:"; tail -40 "$VLOG"; exit 1; }
echo "vLLM ready on $SOCK"

# Prove the model server is sealed too: from inside its instance, the internet must be
# unreachable. Abort the run if it is not.
if apptainer exec "instance://$VINST" python3 -c \
     "import socket; socket.create_connection(('huggingface.co', 443), 10)" >/dev/null 2>&1 \
   || apptainer exec "instance://$VINST" python3 -c \
     "import socket; socket.create_connection(('140.82.112.3', 443), 10)" >/dev/null 2>&1; then
  echo "ABORT: the vLLM container can reach the internet"; exit 1
fi
echo '{"vllm_network_sealed": true}' > "logs/vllm-selftest-$MODEL-$JOBTAG.json"
echo "vLLM container sealed: no internet access"

# WORKERS agents share the one vLLM server: the task list is split into WORKERS parts and
# each part runs in its own process (each builds Java, so keep WORKERS <= cpus / 8).
WORKERS=${WORKERS:-4}
PARTS=$(mktemp -d)
split -n "l/$WORKERS" "$TASKS" "$PARTS/part_"
for P in "$PARTS"/part_*; do
  [[ -s $P ]] || continue
  RB_RUNTIME=${RB_RUNTIME:-frozen} scripts/run_experiment.sh \
    "$MODEL" "$SOCK" "$P" "$OUT" "$IMAGES" "$CACHE" "$RUNS" \
    >"logs/agents-$MODEL-${SLURM_JOB_ID:-local}-$(basename "$P").log" 2>&1 &
done
wait
python3 -I scripts/summarize.py "$OUT" "$RUNS"
