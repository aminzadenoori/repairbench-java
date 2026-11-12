#!/usr/bin/env bash
# Phase 2: download every dependency a task needs, while the network is ON.
# Run inside the matching JDK image on a network node, once per task. Afterwards the
# offline runs (validation, agent, evaluation) use only $CACHE.
#
#   apptainer exec --bind $AI4I_ROOT java-ubuntu22.04-jdk11.sif \
#       scripts/warm_dependencies.sh out/exports/gson/google__gson-2337 $AI4I_ROOT/cache/java
#
# The task is built with gold.patch AND test.patch applied, so test-only dependencies
# and the Surefire/JUnit providers are also downloaded.
set -euo pipefail
TASK=${1:?usage: warm_dependencies.sh <task_dir> <cache_dir>}
CACHE=${2:?usage: warm_dependencies.sh <task_dir> <cache_dir>}
TASK=$(cd "$TASK" && pwd)
mkdir -p "$CACHE/m2" "$CACHE/gradle"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

meta() { python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{},{"d":d}) or "")' "$TASK/metadata.json" "$1"; }
TOOL=$(meta 'd["environment"]["build_tool"]')
TEST_CMD=$(meta 'd["tests"]["test_command"]')

git clone --quiet "$TASK/repo.bundle" "$WORK/repo"
cd "$WORK/repo"
git checkout --quiet repairbench-base
git apply --whitespace=nowarn "$TASK/gold.patch"
git apply --whitespace=nowarn "$TASK/test.patch"

case "$TOOL" in
  maven)
    # 1) plugins + dependencies for compile and test, 2) the exact test run once online
    #    so Surefire's JUnit provider is resolved too. Test failures are fine here.
    mvn -B -q -Dmaven.repo.local="$CACHE/m2" -DskipTests dependency:go-offline test-compile || true
    ${TEST_CMD/mvn -o/mvn} -Dmaven.repo.local="$CACHE/m2" >/dev/null 2>&1 || true
    ;;
  gradle)
    export GRADLE_USER_HOME="$CACHE/gradle"
    # The wrapper downloads Gradle itself; keep that copy in the cache as well.
    if [[ -x ./gradlew ]]; then ./gradlew --version >/dev/null; fi
    GRADLE=gradle; [[ -x ./gradlew ]] && GRADLE=./gradlew
    $GRADLE --continue testClasses >/dev/null 2>&1 || true
    ${TEST_CMD/gradle --offline/$GRADLE} >/dev/null 2>&1 || true
    ;;
  *) echo "unknown build tool for $TASK" >&2; exit 2 ;;
esac
echo "warmed $(basename "$TASK") into $CACHE"
