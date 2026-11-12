#!/usr/bin/env bash
# Phase 5 smoke check for ONE task, offline: ORACLE (base+gold+tests) then BASE (base+tests).
# This is a standalone check to bring up the Java runtime before using the canonical
# RepairBench validator; it does not replace it.
#
#   scripts/smoke_validate.sh <task_dir> <image.sif> <cache_dir> [repetitions]
#
# Writes <task_dir>/smoke/{oracle,base}-<n>.json and <task_dir>/smoke/verdict.json.
set -euo pipefail
TASK=${1:?usage: smoke_validate.sh <task_dir> <image.sif> <cache_dir> [repetitions]}
IMAGE=${2:?image}
CACHE=${3:?cache}
REPS=${4:-3}
TASK=$(cd "$TASK" && pwd); CACHE=$(cd "$CACHE" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$TASK/smoke"

meta() { python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));v=eval(sys.argv[2],{},{"d":d});print(" ".join(v) if isinstance(v,list) else (v or ""))' "$TASK/metadata.json" "$1"; }
TOOL=$(meta 'd["environment"]["build_tool"]')
TEST_CMD=$(meta 'd["tests"]["test_command"]')
GLOBS=$(meta 'd["tests"]["test_report_globs"]')
[[ -n "$TEST_CMD" ]] || { echo "no test command in metadata" >&2; exit 2; }

run_variant() {  # $1 = oracle|base, $2 = repetition
  local W; W=$(mktemp -d)
  git clone --quiet "$TASK/repo.bundle" "$W/repo"
  git -C "$W/repo" checkout --quiet repairbench-base
  [[ $1 == oracle ]] && git -C "$W/repo" apply --whitespace=nowarn "$TASK/gold.patch"
  git -C "$W/repo" apply --whitespace=nowarn "$TASK/test.patch"
  # Maven writes to its local repository, so give each run a writable copy-on-use path
  # seeded from the warmed cache (Phase 2 plan); Gradle reads the cache read-only.
  local ENVS=(--env "GRADLE_RO_DEP_CACHE=/cache/gradle/caches" --env "GRADLE_USER_HOME=/work/.gradle")
  [[ $TOOL == maven ]] && cp -r "$CACHE/m2" "$W/m2"
  local CMD="$TEST_CMD"
  [[ $TOOL == maven ]] && CMD="$CMD -Dmaven.repo.local=/work/m2"
  apptainer exec --net --network none --containall \
      --bind "$W:/work" --bind "$CACHE:/cache:ro" "${ENVS[@]}" --pwd /work/repo \
      "$IMAGE" bash -lc "$CMD" >"$TASK/smoke/$1-$2.log" 2>&1 || true
  # shellcheck disable=SC2086
  python3 -I "$HERE/parse_junit.py" "$W/repo" $GLOBS >"$TASK/smoke/$1-$2.json"
  rm -rf "$W"
}

for i in $(seq 1 "$REPS"); do
  run_variant oracle "$i"
  run_variant base "$i"
done

python3 -I - "$TASK/smoke" "$REPS" <<'EOF' | tee "$TASK/smoke/verdict.json"
import json, sys
d, reps = sys.argv[1], int(sys.argv[2])
runs = [(json.load(open(f"{d}/oracle-{i}.json")), json.load(open(f"{d}/base-{i}.json"))) for i in range(1, reps + 1)]
def lists(o, b):
    f2p = sorted(t for t, s in o.items() if s == "passed" and b.get(t, "missing") != "passed")
    p2p = sorted(t for t, s in o.items() if s == "passed" and b.get(t) == "passed")
    oracle_bad = sorted(t for t, s in o.items() if s in ("failed", "error"))
    return f2p, p2p, oracle_bad
res = [lists(o, b) for o, b in runs]
stable = all(r == res[0] for r in res)
f2p, p2p, bad = res[0]
if not runs[0][0]:
    verdict = "oracle_no_test_results"      # build failed or no reports: environment problem
elif bad:
    verdict = "oracle_failed"
elif not f2p:
    verdict = "bug_not_reproduced"
elif not stable:
    verdict = "unstable"
else:
    verdict = "valid_fail_to_pass"
print(json.dumps({"verdict": verdict, "stable_across_repetitions": stable,
                  "fail_to_pass": f2p, "pass_to_pass": p2p, "oracle_failures": bad}, indent=1))
EOF
