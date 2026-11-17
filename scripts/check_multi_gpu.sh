#!/usr/bin/env bash
# Check that a model really runs across several GPUs in the sealed vLLM container.
# Run it ON a GPU node, inside a Slurm allocation with that many GPUs, e.g.
#   srun --partition=gpuq --gres=gpu:h200:2 --cpus-per-task=16 --mem=128G --time=1:00:00 --pty bash
#   cd ~/repairbench-java && source scripts/env.sh
#   scripts/check_multi_gpu.sh                     # qwen3-coder-next on its 2 GPUs
#   scripts/check_multi_gpu.sh gpt-oss-120b 2      # any downloaded model, any GPU count
#
# It starts the model with tensor-parallel = number of GPUs, waits until it answers on its
# socket, then checks: vLLM reports that tensor-parallel size; EVERY GPU of this job holds a
# large share of memory (each loads its part of the model); one chat answer comes back.
# Then it stops the server. Exit 0 = all checks passed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
MODEL=${1:-qwen3-coder-next}
TP=${2:-$(python3 -I -c 'import json,sys; print(next(m.get("tensor_parallel",1) for m in json.load(open(sys.argv[1]))["models"] if m["name"]==sys.argv[2]))' "$HERE/../configs/models.json" "$MODEL")}
: "${MODELS_ROOT:?source scripts/env.sh first}"
mkdir -p "$HERE/../logs"

ID=$("$HERE/new_id.sh")
SOCK=/tmp/${USER:-$(id -un)}-rb/$ID/vllm.sock
LOG=$HERE/../logs/check-multi-gpu-$MODEL-$ID.log
fail=0
ok()  { echo "  OK    $*"; }
bad() { echo "  FAIL  $*"; fail=1; }

echo "model $MODEL on $TP GPU(s), node $(hostname), CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-<unset>}"
GPUS=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | grep -c . || true)
(( GPUS >= TP )) || { echo "this shell sees $GPUS GPU(s); ask Slurm for $TP (--gres=gpu:h200:$TP)"; exit 2; }

"$HERE/serve_model.sh" "$MODEL" "$SOCK" "$TP" >"$LOG" 2>&1 &
VLLM=$!
trap 'kill $VLLM 2>/dev/null; wait $VLLM 2>/dev/null; rm -rf "$(dirname "$SOCK")"' EXIT
echo "log: $LOG   (loading can take several minutes)"

ready() { curl -sf --unix-socket "$SOCK" http://localhost/v1/models >/dev/null 2>&1; }
for _ in $(seq 1 120); do
  ready && break
  kill -0 $VLLM 2>/dev/null || break
  sleep 15
done
if ! ready; then
  echo "vLLM did not come up. Last lines of the log:"
  tail -30 "$LOG" | cut -c1-250
  exit 1
fi
ok "vLLM answers on $SOCK"

# 1. vLLM itself says it uses TP GPUs
if grep -q "tensor_parallel_size=$TP" "$LOG"; then ok "vLLM started with tensor_parallel_size=$TP"
else bad "the log does not show tensor_parallel_size=$TP"; fi

# 2. every GPU of this job holds a large part of the model (vLLM reserves 90-95% of each)
SEL=(); [[ -n ${CUDA_VISIBLE_DEVICES:-} ]] && SEL=(-i "$CUDA_VISIBLE_DEVICES")
while IFS=, read -r idx used total; do
  pct=$(( used * 100 / total ))
  if (( pct >= 50 )); then ok "GPU $idx: $used / $total MiB used ($pct%)"
  else bad "GPU $idx: only $used / $total MiB used ($pct%): this GPU is not holding part of the model"; fi
done < <(nvidia-smi "${SEL[@]}" --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null \
         | tr -d ' ' | head -n "$TP")

# 3. one answer
ANSWER=$(curl -s --unix-socket "$SOCK" http://localhost/v1/chat/completions -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word.\"}],\"max_tokens\":20}" \
  | python3 -I -c '
import json, sys
m = json.load(sys.stdin)["choices"][0]["message"]
calls = m.get("tool_calls") or []
print(m.get("content") or ("tool call " + calls[0]["function"]["name"] if calls else ""))' 2>/dev/null)
if [[ -n $ANSWER ]]; then ok "the model answered: $(echo "$ANSWER" | head -c 80)"
else bad "no answer to a chat request"; fi

echo
if (( fail == 0 )); then echo "PASSED: $MODEL runs across $TP GPUs in the sealed container"
else echo "FAILED: see above and $LOG"; fi
exit $fail
