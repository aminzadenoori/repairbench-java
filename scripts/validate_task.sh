#!/usr/bin/env bash
# Stage 1 validation (network OFF), ORACLE-first like the C/C++ pipeline:
#   1. search profiles (built runtime: the task's JDK first, then RB_JDK_ORDER; frozen
#      runtime: the task's own image) for one where base + gold + tests builds and every
#      selected test passes;
#   2. freeze that profile, then run ORACLE and BASE <repetitions> times each;
#   3. fail-to-pass = pass in ORACLE, not pass in BASE; pass-to-pass = pass in both;
#      the lists must be identical in every repetition.
#
#   [RB_RUNTIME=built|frozen] scripts/validate_task.sh <task_dir> <images_dir> <cache_dir> [repetitions=3]
#
# Writes <task>/validation/{oracle,base}-<profile>-<n>.{json,log} and validation/verdict.json:
#   valid_fail_to_pass | bug_not_reproduced | oracle_failed | oracle_no_test_results | unstable
set -euo pipefail
. "$(dirname "$0")/lib.sh"
TASK=$(cd "${1:?task_dir}" && pwd)
IMAGES=$(cd "${2:?images_dir}" && pwd)
CACHE=$(cd "${3:?cache_dir}" && pwd)
REPS=${4:-3}
V="$TASK/validation"; mkdir -p "$V"

run_variant() {  # <oracle|base> <profile> <rep>
  local W; W=$(mktemp -d)
  make_workspace "$TASK" "$W" base
  [[ $1 == oracle ]] && apply_patch "$W" "$TASK/gold.patch"
  apply_patch "$W" "$TASK/test.patch"
  rb_setup "$TASK" "$W" "$CACHE"
  local CMD; CMD=$(task_test_command "$TASK" "$W") || die "no test command in metadata"
  run_offline "$(image_for "$IMAGES" "$2" "$TASK")" "$W" "$V/$1-$2-$3.log" "$CMD" || true
  collect_results "$W" "$TASK" "$V/$1-$2-$3.json"
  rm -rf "$W"
}

oracle_ok() {  # <results.json> -> 0 if there are results and none failed
  python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))
sys.exit(0 if r and not any(s in ("failed", "error") for s in r.values()) else 1)' "$1"
}

LOCKED=""; TRIED=()
for P in $(jdk_profiles "$TASK" "$IMAGES"); do
  TRIED+=("$P")
  run_variant oracle "$P" 1
  if oracle_ok "$V/oracle-$P-1.json"; then LOCKED=$P; break; fi
done
[[ ${#TRIED[@]} -gt 0 ]] || die "no image found for $(task_id "$TASK") (runtime $RB_RUNTIME, images in $IMAGES)"

if [[ -n $LOCKED ]]; then
  run_variant base "$LOCKED" 1
  for i in $(seq 2 "$REPS"); do
    run_variant oracle "$LOCKED" "$i"
    run_variant base "$LOCKED" "$i"
  done
fi

python3 -I - "$V" "$REPS" "$LOCKED" "${TRIED[*]}" "$RB_RUNTIME" <<'EOF' | tee "$V/verdict.json"
import json, sys
V, reps, prof, tried, runtime = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4].split(), sys.argv[5]
out = {"runtime": runtime, "jdk": prof or None, "tried_profiles": tried, "repetitions": reps}
if not prof:
    first = json.load(open(f"{V}/oracle-{tried[0]}-1.json"))
    out["verdict"] = "oracle_failed" if first else "oracle_no_test_results"
    out["oracle_failures"] = sorted(t for t, s in first.items() if s in ("failed", "error"))
else:
    def lists(i):
        o = json.load(open(f"{V}/oracle-{prof}-{i}.json"))
        b = json.load(open(f"{V}/base-{prof}-{i}.json"))
        f2p = sorted(t for t, s in o.items() if s == "passed" and b.get(t) != "passed")
        p2p = sorted(t for t, s in o.items() if s == "passed" and b.get(t) == "passed")
        bad = sorted(t for t, s in o.items() if s in ("failed", "error"))
        return f2p, p2p, bad
    runs = [lists(i) for i in range(1, reps + 1)]
    f2p, p2p, bad = runs[0]
    stable = all(r == runs[0] for r in runs)
    out.update(fail_to_pass=f2p, pass_to_pass=p2p, oracle_failures=bad, stable=stable)
    out["verdict"] = ("unstable" if not stable else "oracle_failed" if bad
                      else "bug_not_reproduced" if not f2p else "valid_fail_to_pass")
print(json.dumps(out, indent=1))
EOF
