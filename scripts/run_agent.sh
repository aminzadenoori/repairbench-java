#!/usr/bin/env bash
# Stage 2 (network OFF for everything the model touches): one model, one task.
#   [RB_RUNTIME=built|frozen] scripts/run_agent.sh <task_dir> <model_name> <model> \
#                                                  <images_dir> <cache_dir> <runs_dir>
# <model> is the vLLM socket file (from serve_model.sh), e.g. /tmp/$USER-rb-123/vllm.sock
#   (unix://<socket>:/v1 is accepted too). An http://host:port/v1 URL also works, but then
#   the agent can only run on the host (the sealed container has no network).
# Knobs: RB_HISTORY=none|base (default none, like the C++ no-history pilot),
#   RB_MAX_STEPS (100), RB_MAX_SECONDS (3600), RB_TEMPERATURE (0), KEEP_WORKSPACE=1,
#   RB_ALLOW_UNVALIDATED=1 (run tasks without a valid_fail_to_pass verdict),
#   RB_AGENT_WHERE=container|host (default container; see below), RB_PROXY_PORT (8000).
#
# Fresh workspace from repo.bundle (no remote) -> offline Apptainer instance on the profile
# frozen by validation, with the model's socket file mounted at /rb/sock -> leak self-test
# (abort if it fails) -> the agent runs INSIDE that sealed instance: a forwarder listens on
# its own 127.0.0.1:8000 and passes requests to the socket, the agent uses
# http://127.0.0.1:8000/v1 and runs its tool commands locally -> candidate.patch = full
# workspace diff (computed on the host) -> stop the instance.
# Fallback "host": if the image has no python3 >= 3.7 (or RB_AGENT_WHERE=host), the agent
# loop runs on the host, talks to the socket directly, and sends each tool command into the
# sealed instance with `apptainer exec`. run.json records which one was used.
#
# Output: <runs>/<model>/<instance_id>/{candidate.patch, trajectory.jsonl, agent.json,
#                                         selftest.json, run.json}
set -euo pipefail
. "$(dirname "$0")/lib.sh"
TASK=$(cd "${1:?task_dir}" && pwd)
MODEL=${2:?model_name}
MODEL_ARG=${3:?model socket, e.g. /tmp/$USER-rb-123/vllm.sock}
IMAGES=$(cd "${4:?images_dir}" && pwd)
CACHE=$(cd "${5:?cache_dir}" && pwd)
RUNS=${6:?runs_dir}
HISTORY=${RB_HISTORY:-none}
ID=$(task_id "$TASK")
WHERE=${RB_AGENT_WHERE:-container}
PORT=${RB_PROXY_PORT:-8000}
case $MODEL_ARG in
  http://*|https://*) SOCK=""; WHERE=host; HOST_URL=$MODEL_ARG ;;
  unix://*) SOCK=${MODEL_ARG#unix://}; SOCK=${SOCK%%:*} ;;
  *) SOCK=$MODEL_ARG ;;
esac
if [[ -n $SOCK ]]; then
  [[ -S $SOCK ]] || die "model socket $SOCK does not exist (is vLLM running on this node?)"
  SOCK=$(cd "$(dirname "$SOCK")" && pwd)/$(basename "$SOCK")
  HOST_URL=unix://$SOCK:/v1
fi
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

# The agent's own files (read-only), its output folder, and the model's socket folder are
# mounted into the sealed instance. Nothing in them gives network access.
AGENT_BINDS=(--bind "$RB_SCRIPTS/../agent:/rb/agent:ro" --bind "$OUT:/rb/out")
[[ -n $SOCK ]] && AGENT_BINDS+=(--bind "$(dirname "$SOCK"):/rb/sock")
cp "$TASK/problem_statement.md" "$OUT/problem_statement.md"

apptainer instance start --net --network none --containall --no-home \
  "${RB_BINDS[@]}" "${AGENT_BINDS[@]}" "${RB_OFFLINE_ENV[@]}" "$IMG" "$INST" >/dev/null \
  || die "could not start an instance with --network none; refusing to run the agent with network"

# Commands inside the instance: same environment as validation and evaluation
EXEC=(apptainer exec --pwd /work/repo "${RB_OFFLINE_ENV[@]}" "instance://$INST")
HIDDEN=$(meta "$TASK" 'd["environment"].get("frozen_image_repo_path")' || true)
[[ $RB_RUNTIME == frozen ]] || HIDDEN=""

STATUS=ok
if ! "$RB_SCRIPTS/leak_selftest.sh" "$OUT/selftest.json" "$HISTORY" "$HIDDEN" -- "${EXEC[@]}"; then
  STATUS=leak_selftest_failed
fi

if [[ $STATUS == ok && $WHERE == container ]]; then
  if ! "${EXEC[@]}" python3 -I -c 'import sys, asyncio; sys.exit(sys.version_info < (3, 7))' >/dev/null 2>&1; then
    echo "$ID: no python3 >= 3.7 in the image; running the agent on the host instead"
    WHERE=host
  fi
fi
AGENT_ARGS=(--model "$MODEL" --repo-dir /work/repo
  --max-steps "${RB_MAX_STEPS:-100}" --max-seconds "${RB_MAX_SECONDS:-3600}"
  --temperature "${RB_TEMPERATURE:-0}")
LIMIT=$(( ${RB_MAX_SECONDS:-3600} + 900 ))       # hard stop for the whole agent run

if [[ $STATUS == ok && $WHERE == container ]]; then
  rc=0
  timeout "$LIMIT" "${EXEC[@]}" bash /rb/agent/in_container.sh "/rb/sock/$(basename "$SOCK")" "$PORT" -- \
    "${AGENT_ARGS[@]}" --problem /rb/out/problem_statement.md \
    --trajectory /rb/out/trajectory.jsonl --result /rb/out/agent.json \
    >"$OUT/agent.log" 2>&1 || rc=$?
  if [[ $rc == 97 ]]; then
    echo "$ID: the forwarder could not start in the container; running the agent on the host instead"
    WHERE=host
  elif [[ $rc != 0 ]]; then
    STATUS=agent_crashed
  fi
fi
if [[ $STATUS == ok && $WHERE == host ]]; then
  EXEC_JSON=$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${EXEC[@]}")
  timeout "$LIMIT" python3 -I "$RB_SCRIPTS/../agent/agent.py" --base-url "$HOST_URL" \
    --exec-prefix "$EXEC_JSON" "${AGENT_ARGS[@]}" --problem "$TASK/problem_statement.md" \
    --trajectory "$OUT/trajectory.jsonl" --result "$OUT/agent.json" \
    >"$OUT/agent.log" 2>&1 || STATUS=agent_crashed
fi

if [[ $STATUS == ok ]]; then
  # candidate.patch: everything the agent changed, as one binary-safe diff against base
  git -C "$W/repo" add -A
  git -C "$W/repo" diff --cached --binary HEAD > "$OUT/candidate.patch"
fi

python3 -I - "$OUT/run.json" "$STATUS" "$ID" "$MODEL" "$MODEL_ARG" "$HISTORY" "$RB_RUNTIME" \
  "$PROFILE" "$IMG" "$STARTED" "${RB_MAX_STEPS:-100}" "${RB_MAX_SECONDS:-3600}" "$WHERE" <<'EOF'
import json, os, sys
(out, status, task, model, url, history, runtime, profile, img, started, steps, secs, where) = sys.argv[1:14]
patch = os.path.join(os.path.dirname(out), "candidate.patch")
sha = img + ".sha256"
json.dump({"status": status, "task": task, "model": model, "base_url": url,
           "agent_location": where, "history_profile": history, "runtime": runtime, "profile": profile, "image": img,
           "image_sha256": open(sha).read().strip() if os.path.exists(sha) else None,
           "started": started,
           "candidate_patch_bytes": os.path.getsize(patch) if os.path.exists(patch) else None,
           "max_steps": int(steps), "max_seconds": int(secs)}, open(out, "w"), indent=1)
EOF
echo "$ID [$MODEL]: $STATUS -> $OUT"
