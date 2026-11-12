#!/usr/bin/env bash
# End-to-end test of the pipeline WITHOUT Apptainer, Maven or a GPU.
# A fake `apptainer`, a fake `mvn` and a scripted model server drive one synthetic Java
# task through:
#   validate (ORACLE/BASE x3) -> agent run with leak self-test -> evaluation -> metrics,
# for both runtimes (built and frozen). Works as a normal user; the network is cut with
# `unshare -rn` when user namespaces are allowed (see tests/fake/apptainer for the modes).
#   tests/e2e_fake.sh            (E2E_DIR=<dir> keeps the test folder for inspection)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=${E2E_DIR:-$(mktemp -d)}; trap 'kill $SRV 2>/dev/null || true; [[ -n ${E2E_DIR:-} ]] || rm -rf "$T"' EXIT
export PATH="$ROOT/tests/fake:$PATH" FAKE_APPTAINER_STATE="$T/state"
OUT="$T/out"; TASK="$OUT/exports/demo/demo__calc-1"; mkdir -p "$TASK" "$T/images/tasks" "$T/cache"

# --- a tiny repository with a bug, and its fix/test patches
R="$T/src"; mkdir -p "$R/src/main/java/demo" "$R/src/test/java/demo"
printf 'package demo;\npublic class Calc {\n  public static int add(int a, int b) {\n    return a - b;\n  }\n}\n' > "$R/src/main/java/demo/Calc.java"
printf 'package demo;\npublic class CalcTest {\n  @Test public void testSub() {}\n}\n' > "$R/src/test/java/demo/CalcTest.java"
git -C "$R" init -q -b main; git -C "$R" add -A
git -C "$R" -c user.name=t -c user.email=t@t commit -qm base
cp -r "$R" "$T/fix"; sed -i 's/return a - b;/return a + b;/' "$T/fix/src/main/java/demo/Calc.java"
git -C "$T/fix" diff > "$TASK/gold.patch"; git -C "$T/fix" checkout -q .
sed -i 's|  @Test public void testSub() {}|  @Test public void testSub() {}\n  @Test public void testAdd() { /* 2+3 == 5 */ }|' "$T/fix/src/test/java/demo/CalcTest.java"
git -C "$T/fix" diff > "$TASK/test.patch"
git -C "$R" branch -q repairbench-base
git -C "$R" bundle create -q "$TASK/repo.bundle" repairbench-base
echo "Calc.add(2, 3) returns -1 instead of 5. Addition is broken in demo.Calc." > "$TASK/problem_statement.md"
cat > "$TASK/metadata.json" <<'EOF'
{"instance_id": "demo__calc-1", "repository": "demo/calc", "base_commit": "",
 "environment": {"jdk": "11", "build_tool": "maven",
                 "frozen_image": "docker://example/demo:1", "frozen_image_repo_path": "/testbed",
                 "frozen_java_home": null},
 "tests": {"test_command": "mvn -o -B clean verify -Dtest=CalcTest -DfailIfNoTests=false",
           "test_report_globs": ["**/target/surefire-reports/TEST-*.xml"]},
 "review_flags": []}
EOF
echo '[{"instance_id": "demo__calc-1", "repository": "demo/calc", "task_dir": "exports/demo/demo__calc-1", "review_flags": []}]' > "$OUT/manifest.json"
touch "$T/images/java-ubuntu22.04-jdk11.sif" "$T/images/tasks/demo__calc-1.sif"
mkdir -p /testbed 2>/dev/null || true; mkdir -p /testbed/.git 2>/dev/null || true   # "image's" own repo copy

PORT=$((20000 + RANDOM % 20000))
python3 -I "$ROOT/tests/fake/model_server.py" "$PORT" & SRV=$!
sleep 1

MODE=$(apptainer fake-mode)
echo "fake apptainer mode: $MODE"
[[ $MODE == plain ]] && echo "note: user namespaces are not available here, so the network can't be cut; the leak self-test will fail if this node has internet access"

show_logs() {  # print what is needed to see why a check failed
  echo "----- diagnostics ($T kept) -----"
  for f in "$TASK"/validation/*.log "$T"/runs/*/demo__calc-1/*.log "$T"/runs/*/demo__calc-1/*.json; do
    [[ -f $f ]] || continue
    echo "== $f"; tail -n 25 "$f"
  done
  E2E_DIR=keep
}
check() {
  if [[ ! -f $1 ]]; then echo "missing: $1"; show_logs; exit 1; fi
  python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2],{},{'d':d}); print(sys.argv[1].split('/')[-1], '->', v); sys.exit(0 if v else 1)" "$1" "$2" \
    || { show_logs; exit 1; }
}

for RT in built frozen; do
  echo "=== runtime: $RT"
  export RB_RUNTIME=$RT
  rm -rf "$TASK/validation" "$T/runs"
  "$ROOT/scripts/validate_task.sh" "$TASK" "$T/images" "$T/cache" 3 >/dev/null
  check "$TASK/validation/verdict.json" 'd["verdict"]=="valid_fail_to_pass" and d["fail_to_pass"]==["demo.CalcTest::testAdd"] and d["pass_to_pass"]==["demo.CalcTest::testSub"]'
  "$ROOT/scripts/run_agent.sh" "$TASK" fake-model "http://127.0.0.1:$PORT/v1" "$T/images" "$T/cache" "$T/runs"
  RD="$T/runs/fake-model/demo__calc-1"
  check "$RD/selftest.json" 'd["passed"]'
  check "$RD/agent.json" 'd["stop_reason"]=="finished"'
  grep -q '^+    return a + b;' "$RD/candidate.patch" && echo "candidate.patch contains the fix"
  "$ROOT/scripts/evaluate_candidate.sh" "$TASK" "$RD" "$T/images" "$T/cache" >/dev/null
  check "$RD/result.json" 'd["outcome"]=="resolved"'
  # A wrong patch must be scored unresolved, an empty one as empty_patch
  mkdir -p "$T/runs/bad-model/demo__calc-1" "$T/runs/empty-model/demo__calc-1"
  sed 's/a + b/a * b/' "$RD/candidate.patch" > "$T/runs/bad-model/demo__calc-1/candidate.patch"
  : > "$T/runs/empty-model/demo__calc-1/candidate.patch"
  "$ROOT/scripts/evaluate_candidate.sh" "$TASK" "$T/runs/bad-model/demo__calc-1" "$T/images" "$T/cache" >/dev/null
  "$ROOT/scripts/evaluate_candidate.sh" "$TASK" "$T/runs/empty-model/demo__calc-1" "$T/images" "$T/cache" >/dev/null
  check "$T/runs/bad-model/demo__calc-1/result.json" 'd["outcome"]=="unresolved" and d["f2p_failing"]==["demo.CalcTest::testAdd"]'
  check "$T/runs/empty-model/demo__calc-1/result.json" 'd["outcome"]=="empty_patch"'
  python3 -I "$ROOT/scripts/summarize.py" "$OUT" "$T/runs" | grep -E '^\| (fake|bad|empty)'
done
echo "ALL E2E CHECKS PASSED"
