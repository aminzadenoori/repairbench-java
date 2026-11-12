#!/usr/bin/env bash
# Stage 1 over many tasks.
#   RB_RUNTIME=built  : warm dependencies (network ON), then validate (network OFF)
#   RB_RUNTIME=frozen : pull each task's image + extract its caches (network ON), then validate
#
#   [RB_RUNTIME=built|frozen] scripts/stage1_all.sh <out_dir> <images_dir> <cache_dir> [owner/repo | instance_id ...]
#
# Resumable: tasks with validation/verdict.json are skipped (delete it to redo). If compute
# nodes have no network, run with ONLY_PREPARE=1 on a network node first, then with
# ONLY_VALIDATE=1 on compute nodes. Writes <out>/validated_tasks.txt at the end.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
OUT=$(cd "${1:?out_dir}" && pwd); IMAGES=${2:?images_dir}; CACHE=${3:?cache_dir}; shift 3
mkdir -p "$IMAGES" "$CACHE"
REPS=${RB_REPETITIONS:-3}

if [[ $RB_RUNTIME == frozen && -z ${ONLY_VALIDATE:-} ]]; then
  "$HERE/pull_task_images.sh" "$OUT" "$IMAGES" "$CACHE" "$@"
fi

python3 -I - "$OUT/manifest.json" "$@" <<'EOF' |
import json, sys
only = set(sys.argv[2:])
for t in json.load(open(sys.argv[1])):
    if (not only or t["repository"] in only or t["instance_id"] in only) and "patch_does_not_apply" not in t["review_flags"]:
        print(t["task_dir"])
EOF
while read -r TD; do
  T="$OUT/$TD"
  [[ -f $T/repo.bundle ]] || { echo "no bundle: $TD (run make_bundles.sh)"; continue; }
  if [[ $RB_RUNTIME == built && -z ${ONLY_VALIDATE:-} && ! -f $T/warm/.done ]]; then
    "$HERE/warm_dependencies.sh" "$T" "$CACHE" "$IMAGES" </dev/null && touch "$T/warm/.done" || echo "warm failed: $TD"
  fi
  if [[ -z ${ONLY_PREPARE:-} && ! -f $T/validation/verdict.json ]]; then
    "$HERE/validate_task.sh" "$T" "$IMAGES" "$CACHE" "$REPS" </dev/null >/dev/null || echo "validate error: $TD"
    python3 -I -c 'import json,sys;print(sys.argv[2], json.load(open(sys.argv[1]))["verdict"])' \
        "$T/validation/verdict.json" "$(basename "$T")" 2>/dev/null || true
  fi
done

python3 -I - "$OUT" <<'EOF'
import json, sys
from collections import Counter
from pathlib import Path
out = Path(sys.argv[1])
c, ids = Counter(), []
for t in json.load(open(out / "manifest.json")):
    v = out / t["task_dir"] / "validation" / "verdict.json"
    verdict = json.load(open(v))["verdict"] if v.exists() else "not_validated"
    c[verdict] += 1
    if verdict == "valid_fail_to_pass":
        ids.append(t["instance_id"])
(out / "validated_tasks.txt").write_text("\n".join(ids) + "\n")
print(dict(c))
print(f"{len(ids)} validated task ids -> {out / 'validated_tasks.txt'}")
EOF
