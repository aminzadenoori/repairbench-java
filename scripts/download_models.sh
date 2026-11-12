#!/usr/bin/env bash
# Download the four models in configs/models.json to shared storage (network node).
#   MODELS_ROOT=/shared/models scripts/download_models.sh [model-name ...]
# Needs: pip install -U "huggingface_hub[cli]"; HF_TOKEN set if a model is gated.
set -euo pipefail
MODELS_ROOT=${MODELS_ROOT:?set MODELS_ROOT to the shared weights folder}
HERE=$(cd "$(dirname "$0")/.." && pwd)
python3 -I - "$HERE/configs/models.json" "$@" <<'EOF' |
import json, sys
want = set(sys.argv[2:])
for m in json.load(open(sys.argv[1]))["models"]:
    if not want or m["name"] in want:
        print(m["name"], m["hf_repo"])
EOF
while read -r NAME REPO; do
  echo "downloading $REPO -> $MODELS_ROOT/$NAME"
  hf download "$REPO" --local-dir "$MODELS_ROOT/$NAME"
  (cd "$MODELS_ROOT/$NAME" && find . -type f ! -path './.cache/*' -print0 | sort -z | xargs -0 sha256sum) \
      > "$MODELS_ROOT/$NAME.sha256"
done
echo "done; record the .sha256 files with the run artifacts"
