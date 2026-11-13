#!/usr/bin/env bash
# Stage 1 (network ON): download everything one task needs into the shared cache.
#   scripts/warm_dependencies.sh <task_dir> <cache_dir> <images_dir> [jdk]
# Cache layout:  <cache>/m2 (Maven local repo)   <cache>/gradle (GRADLE_USER_HOME:
#                caches/modules-2 for dependencies, wrapper/dists for Gradle itself)
# The build runs with gold.patch AND test.patch applied, so test-only dependencies and the
# Surefire/JUnit providers are cached as well. Test failures here are expected and ignored.
set -euo pipefail
RB_RUNTIME=built  # warm-up is only for the built runtime (frozen images bring their caches)
. "$(dirname "$0")/lib.sh"
TASK=$(cd "${1:?task_dir}" && pwd)
CACHE=${2:?cache_dir}; mkdir -p "$CACHE/m2" "$CACHE/gradle"; CACHE=$(cd "$CACHE" && pwd)
IMAGES=$(cd "${3:?images_dir}" && pwd)
JDK=${4:-$(locked_jdk "$TASK")}
[[ -n $JDK ]] || JDK=11
IMG=$(image_for "$IMAGES" "$JDK"); [[ -f $IMG ]] || die "missing image $IMG"
TOOL=$(meta "$TASK" 'd["environment"]["build_tool"]')

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
make_workspace "$TASK" "$W" base
apply_patch "$W" "$TASK/gold.patch"
apply_patch "$W" "$TASK/test.patch"
TEST_CMD=$(task_test_command "$TASK" "$W" || true)

ONLINE=(apptainer exec --containall --no-home --bind "$W:/work" --bind "$CACHE:/cache" --pwd /work/repo
        --env HOME=/work --env GRADLE_USER_HOME=/cache/gradle "$IMG" bash -lc)
case "$TOOL" in
  maven)
    "${ONLINE[@]}" "mvn -B -Dmaven.repo.local=/cache/m2 -DskipTests dependency:go-offline test-compile" \
        >"$W/warm1.log" 2>&1 || true
    if [[ -n $TEST_CMD ]]; then
      # Same command as offline runs, minus -o, so exactly those plugins get resolved.
      "${ONLINE[@]}" "${TEST_CMD/mvn -o /mvn } -Dmaven.repo.local=/cache/m2" >"$W/warm2.log" 2>&1 || true
    fi
    ;;
  gradle)
    G=gradle; [[ -x $W/repo/gradlew ]] && G=./gradlew
    "${ONLINE[@]}" "$G --version && $G --continue testClasses" >"$W/warm1.log" 2>&1 || true
    if [[ -n $TEST_CMD ]]; then
      C=${TEST_CMD/gradle --offline /$G }; C=${C/.\/gradlew --offline /./gradlew }
      "${ONLINE[@]}" "$C" >"$W/warm2.log" 2>&1 || true
    fi
    ;;
  *) die "unknown build tool '$TOOL' for $TASK" ;;
esac
mkdir -p "$TASK/warm"; cp "$W"/warm*.log "$TASK/warm/" 2>/dev/null || true
echo "warmed $(basename "$TASK") (jdk $JDK) into $CACHE"
