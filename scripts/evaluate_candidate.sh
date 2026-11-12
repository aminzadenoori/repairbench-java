#!/usr/bin/env bash
# Stage 3 (network OFF): score one candidate.patch against the hidden tests.
#   [RB_RUNTIME=built|frozen] scripts/evaluate_candidate.sh <task_dir> <run_dir> <images_dir> <cache_dir>
# <run_dir> holds candidate.patch (from run_agent.sh); result.json is written there.
#
# Fresh base checkout -> apply candidate.patch -> restore the files test.patch touches to
# base (SWE-bench convention) -> apply test.patch -> run the task's tests on the JDK frozen
# by validation -> resolved iff every fail-to-pass AND every pass-to-pass test passes.
#
# Outcomes: resolved | unresolved | patch_apply_failed | empty_patch (all count in Pass@1)
#           missing_validation | missing_candidate | eval_no_test_results (kept MISSING,
#           never counted as failures, as in METHODOLOGY.md)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
TASK=$(cd "${1:?task_dir}" && pwd)
RUN=$(cd "${2:?run_dir}" && pwd)
IMAGES=$(cd "${3:?images_dir}" && pwd)
CACHE=$(cd "${4:?cache_dir}" && pwd)
VERDICT="$TASK/validation/verdict.json"
CAND="$RUN/candidate.patch"

write() {  # <outcome> [results.json]
  python3 -I - "$1" "$VERDICT" "${2:-}" "$RUN/result.json" <<'EOF'
import json, os, sys
outcome, verdict_path, results_path, out = sys.argv[1:5]
res = {"outcome": outcome}
if results_path and os.path.exists(results_path) and os.path.exists(verdict_path):
    v = json.load(open(verdict_path)); r = json.load(open(results_path))
    f2p, p2p = v["fail_to_pass"], v["pass_to_pass"]
    res["f2p_failing"] = sorted(t for t in f2p if r.get(t) != "passed")
    res["p2p_failing"] = sorted(t for t in p2p if r.get(t) != "passed")
    res["f2p_passed"] = len(f2p) - len(res["f2p_failing"])
    res["p2p_passed"] = len(p2p) - len(res["p2p_failing"])
    res["f2p_total"], res["p2p_total"] = len(f2p), len(p2p)
    if outcome == "scored":
        if not r:
            res["outcome"] = "eval_no_test_results"
        else:
            res["outcome"] = "resolved" if not res["f2p_failing"] and not res["p2p_failing"] else "unresolved"
res["counts_in_pass_at_1"] = res["outcome"] in ("resolved", "unresolved", "patch_apply_failed", "empty_patch")
json.dump(res, open(out, "w"), indent=1)
print(res["outcome"])
EOF
}

ok_verdict=$(python3 -I -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["verdict"] == "valid_fail_to_pass")
except Exception: print(False)' "$VERDICT")
[[ $ok_verdict == True ]] || { write missing_validation; exit 0; }
[[ -f $CAND ]] || { write missing_candidate; exit 0; }
[[ -s $CAND ]] || { write empty_patch; exit 0; }

PROFILE=$(locked_jdk "$TASK"); IMG=$(image_for "$IMAGES" "$PROFILE" "$TASK")
[[ -f $IMG ]] || die "missing image $IMG"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
make_workspace "$TASK" "$W" base
if ! git -C "$W/repo" apply --whitespace=nowarn --binary "$CAND" 2>"$RUN/apply.log"; then
  write patch_apply_failed; exit 0
fi
reset_test_files "$W" "$TASK/test.patch"
apply_patch "$W" "$TASK/test.patch"
rb_setup "$TASK" "$W" "$CACHE"
CMD=$(task_test_command "$TASK" "$W")
run_offline "$IMG" "$W" "$RUN/eval.log" "$CMD" || true
collect_results "$W" "$TASK" "$RUN/eval_tests.json"
write scored "$RUN/eval_tests.json"
