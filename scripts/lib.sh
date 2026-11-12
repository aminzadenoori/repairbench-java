# Shared helpers for the stage scripts. Source it: . "$(dirname "$0")/lib.sh"
# Everything runs in Apptainer; nothing needs a Docker daemon.
#
# Two runtimes (RB_RUNTIME):
#   built  (default) our images from environments/java.def (one per JDK: 8, 11, 17, 21) and
#          one shared dependency cache made by warm_dependencies.sh
#   frozen one image per task, pulled from the SWE-PolyBench / Multi-SWE-bench registries
#          with `apptainer pull docker://...` (scripts/pull_task_images.sh); the image already
#          has the right JDK, and its Maven/Gradle caches are extracted once per task
#
# Inside every container run:
#   /work/repo         the task's repository (host: $W/repo), from repo.bundle
#   /work/m2           writable Maven local repository
#   /work/gradle-home  writable GRADLE_USER_HOME (wrapper dists + offline init script)
#   /cache             dependency cache, read-only
# shellcheck shell=bash

RB_RUNTIME=${RB_RUNTIME:-built}
RB_IMAGE_PREFIX=${RB_IMAGE_PREFIX:-java-ubuntu22.04-jdk}
RB_JDK_ORDER=${RB_JDK_ORDER:-"11 17 8 21"}   # built runtime: fallback order of the JDK search
RB_GIT_ID=(-c user.name=repairbench -c user.email=repairbench@localhost -c commit.gpgsign=false)
RB_SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() { echo "error: $*" >&2; exit 2; }

# meta <task_dir> <python expression over d>; lists are printed space-separated
meta() {
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2], {}, {"d": d})
print(" ".join(map(str, v)) if isinstance(v, list) else ("" if v is None else v))' "$1/metadata.json" "$2"
}

task_id() { basename "$1"; }

# Image for a profile: a JDK number (built) or "frozen" (the task's own pulled image)
image_for() {  # <images_dir> <profile> <task_dir>
  if [[ $2 == frozen ]]; then echo "$1/tasks/$(task_id "$3").sif"
  else echo "$1/${RB_IMAGE_PREFIX}$2.sif"; fi
}

# Profiles to try for a task, in order
jdk_profiles() {  # <task_dir> <images_dir>
  if [[ $RB_RUNTIME == frozen ]]; then
    [[ -f $(image_for "$2" frozen "$1") ]] && echo frozen
    return 0
  fi
  local first; first=$(meta "$1" 'd["environment"]["jdk"]')
  local out=() j
  for j in $first $RB_JDK_ORDER; do
    [[ " ${out[*]} " == *" $j "* ]] && continue
    [[ -f $(image_for "$2" "$j" "$1") ]] && out+=("$j")
  done
  echo "${out[*]}"
}

# The profile frozen by validation, else the task's own
locked_jdk() {  # <task_dir>
  local v="$1/validation/verdict.json"
  if [[ -f $v ]]; then
    python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("jdk") or "")' "$v"
  elif [[ $RB_RUNTIME == frozen ]]; then
    echo frozen
  else
    meta "$1" 'd["environment"]["jdk"]'
  fi
}

# Per-task dependency cache directory
task_cache() {  # <task_dir> <cache_root>
  if [[ $RB_RUNTIME == frozen ]]; then echo "$2/tasks/$(task_id "$1")"; else echo "$2"; fi
}

# make_workspace <task_dir> <W> <history: none|base>
#   none: a single fresh commit of the base tree (no history, no remote)
#   base: the bundle's history up to the base commit, branch "main", no remote
make_workspace() {
  local task=$1 W=$2 history=${3:-none}
  mkdir -p "$W/empty"
  git clone --quiet "$task/repo.bundle" "$W/repo" 2>/dev/null
  git -C "$W/repo" checkout --quiet -B main origin/repairbench-base
  git -C "$W/repo" remote remove origin   # also drops the remote-tracking refs
  if [[ $history == none ]]; then
    rm -rf "$W/repo/.git"
    git -C "$W/repo" init --quiet -b main
    git -C "$W/repo" add -A
    git "${RB_GIT_ID[@]}" -C "$W/repo" commit --quiet -m "base" --no-verify
  fi
  # Build outputs never count as part of a patch
  printf '%s\n' target/ build/ .gradle/ out/ '*.class' .idea/ >> "$W/repo/.git/info/exclude"
}

# apply_patch <W> <patch> : exact first, then tolerant of whitespace
apply_patch() {
  git -C "$1/repo" apply --whitespace=nowarn "$2" 2>/dev/null ||
    git -C "$1/repo" apply --whitespace=nowarn --ignore-whitespace --recount "$2"
}

# Restore every file test.patch touches to its base state (SWE-bench convention), so that
# agent edits to those files can't block the hidden tests.
reset_test_files() {  # <W> <test.patch>
  local f
  while read -r f; do
    [[ -z $f ]] && continue
    if git -C "$1/repo" cat-file -e "HEAD:$f" 2>/dev/null; then
      git -C "$1/repo" checkout --quiet HEAD -- "$f"
    else
      rm -f "$1/repo/$f"
    fi
  done < <(sed -n 's#^diff --git a/[^ ]* b/##p' "$2")
}

# rb_setup <task_dir> <W> <cache_root>
# Prepares the writable build homes in $W and sets two arrays for container runs:
#   RB_BINDS        bind mounts (workspace, read-only cache, and, for frozen images, an
#                   empty directory over the image's own repo copy so the agent can't read
#                   its git history)
#   RB_OFFLINE_ENV  --env arguments (offline Maven/Gradle, JDK for frozen images)
rb_setup() {
  local task=$1 W=$2 C; C=$(task_cache "$1" "$3")
  mkdir -p "$W/m2" "$W/gradle-home/init.d" "$W/home" "$W/empty" "$C"
  RB_BINDS=(--bind "$W:/work" --bind "$C:/cache:ro")
  local mvn_repo="-Dmaven.repo.local=/work/m2 -Dmaven.repo.local.tail=/cache/m2"
  local gradle_ro=(--env "GRADLE_RO_DEP_CACHE=/cache/gradle/caches")
  if [[ $RB_RUNTIME == frozen ]]; then
    # Small per-task caches: copy them so any Maven/Gradle version can use them.
    [[ -d $C/m2 ]] && cp -r "$C/m2/." "$W/m2/"
    [[ -d $C/gradle ]] && cp -r "$C/gradle/." "$W/gradle-home/"
    mvn_repo="-Dmaven.repo.local=/work/m2"
    gradle_ro=()
    local hide; hide=$(meta "$task" 'd["environment"].get("frozen_image_repo_path")')
    [[ -n $hide ]] && RB_BINDS+=(--bind "$W/empty:$hide")
  elif [[ -d $C/gradle/wrapper ]]; then
    cp -r "$C/gradle/wrapper" "$W/gradle-home/wrapper"
  fi
  cat > "$W/gradle-home/init.d/repairbench-offline.gradle" <<'EOF'
// Written by RepairBench: every Gradle build in this sandbox runs offline.
gradle.startParameter.offline = true
EOF
  RB_OFFLINE_ENV=(
    --env "HOME=/work/home"
    --env "MAVEN_ARGS=-o -B $mvn_repo"
    --env "RB_MAVEN_REPO=$mvn_repo"
    --env "GRADLE_USER_HOME=/work/gradle-home"
    "${gradle_ro[@]}"
    --env "REPAIRBENCH_OFFLINE=1"
  )
  if [[ $RB_RUNTIME == frozen ]]; then
    local jh; jh=$(meta "$task" 'd["environment"].get("frozen_java_home")')
    [[ -n $jh ]] && RB_OFFLINE_ENV+=(--env "JAVA_HOME=$jh")
  fi
  return 0
}

# The task's test command, adapted to the workspace (Gradle wrapper if present; explicit
# Maven repository flags, since Maven < 3.9 in some frozen images ignores MAVEN_ARGS)
task_test_command() {  # <task_dir> <W>
  local cmd; cmd=$(meta "$1" 'd["tests"]["test_command"]')
  [[ -n $cmd ]] || return 1
  if [[ $cmd == gradle\ * && -x $2/repo/gradlew ]]; then
    cmd="./gradlew ${cmd#gradle }"
  fi
  [[ $cmd == mvn\ * ]] && cmd="$cmd \$RB_MAVEN_REPO"
  echo "$cmd"
}

# run_offline <image> <W> <log> <command...> : one container, no network (needs rb_setup)
run_offline() {
  local IMG=$1 W=$2 LOG=$3; shift 3
  apptainer exec --net --network none --containall --no-home \
    "${RB_BINDS[@]}" --pwd /work/repo "${RB_OFFLINE_ENV[@]}" "$IMG" bash -lc "$*" >"$LOG" 2>&1
}

# collect_results <W> <task_dir> <out.json> : parse JUnit XML written in the workspace
collect_results() {
  # shellcheck disable=SC2046
  python3 -I "$RB_SCRIPTS/parse_junit.py" "$1/repo" $(meta "$2" 'd["tests"]["test_report_globs"]') >"$3"
}
