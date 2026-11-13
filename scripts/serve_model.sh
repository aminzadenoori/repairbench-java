#!/usr/bin/env bash
# Start ONE vLLM server for one model, fully sealed: an Apptainer instance with
# --net --network none (no internet, no TCP from outside), the weights mounted read-only,
# Hugging Face offline. It answers on a Unix socket file on the node's local disk, so only
# processes on the SAME node can talk to it: the agent harness of the same Slurm job.
#
#   scripts/serve_model.sh <model-name> <socket-path> [tensor-parallel] [instance-name]
#   e.g. scripts/serve_model.sh gpt-oss-120b /tmp/$USER-rb/vllm.sock 1 rbvllm_123
# Agent containers mount the socket folder and reach it via agent/uds_proxy.py.
# Stays in the foreground while the server runs; stopping it stops the instance.
set -euo pipefail
NAME=${1:?usage: serve_model.sh <model-name> <socket-path> [tp] [instance-name]}
SOCK=${2:?socket path, on a local disk of this node}
TP=${3:-1}
INST=${4:-rbvllm_$$}
MODELS_ROOT=${MODELS_ROOT:?set MODELS_ROOT}
VLLM_SIF=${VLLM_SIF:?set VLLM_SIF to an Apptainer image with vLLM}
HERE=$(cd "$(dirname "$0")/.." && pwd)
[[ -d $MODELS_ROOT/$NAME ]] || { echo "model $NAME not found in $MODELS_ROOT" >&2; exit 2; }

mapfile -t ARGS < <(python3 -I -c '
import json, sys
for m in json.load(open(sys.argv[1]))["models"]:
    if m["name"] == sys.argv[2]:
        print("\n".join(m["vllm_args"])); break
else:
    sys.exit("unknown model " + sys.argv[2])' "$HERE/configs/models.json" "$NAME")

SOCKDIR=$(dirname "$SOCK"); mkdir -p "$SOCKDIR"; rm -f "$SOCK"
STATE=$SOCKDIR/vllm-state-$INST                       # writable caches for vLLM/torch/triton
mkdir -p "$STATE/home"            # --home, not --env HOME (Apptainer refuses that)

# --containall clears the environment, including CUDA_VISIBLE_DEVICES: without it vLLM sees
# every GPU on the node and loads onto GPU 0, which may not be ours. Pass Slurm's choice in.
GPU_ENV=()
[[ -n ${CUDA_VISIBLE_DEVICES:-} ]] && GPU_ENV=(--env "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES")
NGPU=$(apptainer exec --nv --containall "${GPU_ENV[@]}" "$VLLM_SIF" nvidia-smi -L 2>/dev/null | grep -c '^GPU' || true)
echo "GPUs given to vLLM: ${CUDA_VISIBLE_DEVICES:-<all on node>} ($NGPU visible in the container), tensor-parallel $TP"
(( NGPU >= TP )) || { echo "need $TP GPUs for tensor-parallel $TP, the container sees $NGPU" >&2; exit 2; }

apptainer instance start --nv --net --network none --containall --home "$STATE/home" "${GPU_ENV[@]}" \
  --bind "$MODELS_ROOT:/models:ro" --bind "$SOCKDIR:/sock" --bind "$STATE:/state" \
  --env HF_HUB_OFFLINE=1 --env TRANSFORMERS_OFFLINE=1 --env VLLM_NO_USAGE_STATS=1 --env DO_NOT_TRACK=1 \
  --env XDG_CACHE_HOME=/state/cache --env HF_HOME=/state/hf \
  "$VLLM_SIF" "$INST" >/dev/null
trap 'apptainer instance stop "$INST" >/dev/null 2>&1 || true' EXIT

apptainer exec --pwd / "instance://$INST" vllm serve "/models/$NAME" --served-model-name "$NAME" \
  --uds "/sock/$(basename "$SOCK")" --tensor-parallel-size "$TP" "${ARGS[@]}"
