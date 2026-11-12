#!/usr/bin/env bash
# Start ONE OpenAI-compatible vLLM server for one model on this GPU node, fully offline.
#   MODELS_ROOT=/shared/models VLLM_SIF=vllm.sif scripts/serve_model.sh <model-name> [port] [tensor-parallel]
# Agent containers (started with --network none) reach it through a Unix socket or the
# node's loopback, as described in the README; the server itself needs no internet.
set -euo pipefail
NAME=${1:?usage: serve_model.sh <model-name> [port] [tp]}
PORT=${2:-8000}
TP=${3:-1}
MODELS_ROOT=${MODELS_ROOT:?set MODELS_ROOT}
VLLM_SIF=${VLLM_SIF:?set VLLM_SIF to an Apptainer image with vLLM}
HERE=$(cd "$(dirname "$0")/.." && pwd)
mapfile -t ARGS < <(python3 -I -c '
import json, sys
for m in json.load(open(sys.argv[1]))["models"]:
    if m["name"] == sys.argv[2]:
        print("\n".join(m["vllm_args"])); break
else:
    sys.exit("unknown model " + sys.argv[2])' "$HERE/configs/models.json" "$NAME")

exec apptainer exec --nv --bind "$MODELS_ROOT:/models:ro" \
  --env HF_HUB_OFFLINE=1 --env TRANSFORMERS_OFFLINE=1 \
  "$VLLM_SIF" vllm serve "/models/$NAME" --served-model-name "$NAME" \
  --host 127.0.0.1 --port "$PORT" --tensor-parallel-size "$TP" "${ARGS[@]}"
