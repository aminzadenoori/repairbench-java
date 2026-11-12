#!/usr/bin/env bash
# Stage 2 (network OFF for everything the model touches): one model, one task.
#   [RB_RUNTIME=built|frozen] scripts/run_agent.sh <task_dir> <model_name> <base_url> \
#                                                  <images_dir> <cache_dir> <runs_dir>
# Knobs: RB_HISTORY=none|base (default none, like the C++ no-history pilot),
#   RB_MAX_STEPS (100), RB_MAX_SECONDS (3600), RB_TEMPERATURE (0), KEEP_WORKSPACE=1,
#   RB_ALLOW_UNVALIDATED=1 (run tasks without a valid_fail_to_pass verdict).
#
# Fresh workspace from repo.bundle (no remote) -> offline Apptainer instance on the profile
# frozen by validation -> leak self-test (abort if it fails) -> agent loop against the
# local model server -> candidate.patch = full workspace diff -> stop the instance.
#
# Output: <runs>/<model>/<instance_id>/{candidate.patch, trajectory.jsonl, agent.json,
#                                         selftest.json, run.json}
set -euo pipefail
. "$(dirname "$0")/lib.sh"
TASK=$(cd "${1:?task_dir}" && pwd)
MODEL=${2:?model_name}
BASE_URL=${3:?base_url e.g. http://127.0.0.1:8000/v1}
IMAGES=$(cd "${4:?images_dir}" && pwd)
CACHE=$(cd "${5:?cache_dir}" && pwd)
RUNS=${6:?runs_dir}
HISTORY=${RB_HISTORY:-none}
ID=$(task_id "$TASK")
OUT="$RUNS/$MODEL/$ID"; mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)

VERDICT=$(python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["verdict"])
except Exception: print("not_validated")' "$TASK/validation/verdict.json")
if [[ $VERDICT != valid_fail_to_pass && -z ${RB_ALLOW_UNVALIDATED:-} ]]; then
  echo "skip $ID: validation verdict is $VERDICT"
  echo "{\"status\": \"skipped\", \"reason\": \"$VERDICT\"}" > "$OUT/run.json"
  exit 0
fi
PROFILE=$(locked_jdk "$TASK"); IMG=$(image_for "$IMAGES" "$PROFILE" "$TASK")
[[ -f $IMG ]] || die "missing image $IMG"

W=$(mktemp -d "${TMPDIR:-/tmp}/rb-$ID-XXXX")
INST="rb_$(echo "$MODEL-$ID-$$" | md5sum | cut -c1-12)"
cleanup() {
  apptainer instance stop "$INST" >/dev/null 2>&1 || true
  [[ -n ${KEEP_WORKSPACE:-} ]] || rm -rf "$W"
}
trap cleanup EXIT

make_workspace "$TASK" "$W" "$HISTORY"
rb_setup "$TASK" "$W" "$CACHE"
STARTED=$(date -u +%FT%TZ)

apptainer instance start --net --network none --containall --no-home \
  "${RB_BINDS[@]}" "${RB_OFFLINE_ENV[@]}" "$IMG" "$INST" >/dev/null \
  || die "could not start an instance with --network none; refusing to run the agent with network"

# Commands inside the instance: same environment as validation and evaluation
EXEC=(apptainer exec --pwd /work/repo "${RB_OFFLINE_ENV[@]}" "instance://$INST")
HIDDEN=$(meta "$TASK" 'd["environment"].get("frozen_image_repo_path")' || true)
[[ $RB_RUNTIME == frozen ]] || HIDDEN=""

STATUS=ok
if ! "$RB_SCRIPTS/leak_selftest.sh" "$OUT/selftest.json" "$HISTORY" "$HIDDEN" -- "${EXEC[@]}"; then
  STATUS=leak_selftest_failed
fi

if [[ $STATUS == ok ]]; then
  EXEC_JSON=$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${EXEC[@]}")
  python3 -I "$RB_SCRIPTS/../agent/agent.py" --base-url "$BASE_URL" --model "$MODEL" \
    --exec-prefix "$EXEC_JSON" --repo-dir /work/repo --problem "$TASK/problem_statement.md" \
    --trajectory "$OUT/trajectory.jsonl" --result "$OUT/agent.json" \
    --max-steps "${RB_MAX_STEPS:-100}" --max-seconds "${RB_MAX_SECONDS:-3600}" \
    --temperature "${RB_TEMPERATURE:-0}" >/dev/null || STATUS=agent_crashed

  # candidate.patch: everything the agent changed, as one binary-safe diff against base
  git -C "$W/repo" add -A
  git -C "$W/repo" diff --cached --binary HEAD > "$OUT/candidate.patch"
fi

python3 -I - "$OUT/run.json" "$STATUS" "$ID" "$MODEL" "$BASE_URL" "$HISTORY" "$RB_RUNTIME" \
  "$PROFILE" "$IMG" "$STARTED" "${RB_MAX_STEPS:-100}" "${RB_MAX_SECONDS:-3600}" <<'EOF'
import json, os, sys
(out, status, task, model, url, history, runtime, profile, img, started, steps, secs) = sys.argv[1:13]
patch = os.path.join(os.path.dirname(out), "candidate.patch")
sha = img + ".sha256"
json.dump({"status": status, "task": task, "model": model, "base_url": url,
           "history_profile": history, "runtime": runtime, "profile": profile, "image": img,
           "image_sha256": open(sha).read().strip() if os.path.exists(sha) else None,
           "started": started,
           "candidate_patch_bytes": os.path.getsize(patch) if os.path.exists(patch) else None,
           "max_steps": int(steps), "max_seconds": int(secs)}, open(out, "w"), indent=1)
EOF
echo "$ID [$MODEL]: $STATUS -> $OUT"
