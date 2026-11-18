#!/usr/bin/env bash
# Permission test for the group-shared folder (scripts/setup_shared.sh + RB_SHARED), with real
# users: two members of one group and one outsider, under a parent folder with mode 3770 like
# the Foundry's /hpc/home/scratch. Needs root (creates the users); skips otherwise.
#   sudo bash tests/shared_storage_test.sh
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo "SKIP: needs root to create test users"; exit 0; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d /tmp/rb-shared-test.XXXX); chmod 755 "$T"
G=rbtestgrp; U1=rbtest1; U2=rbtest2; U3=rbtest3
cleanup() { for u in $U1 $U2 $U3; do userdel "$u" 2>/dev/null || true; done; groupdel $G 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
groupadd -f $G
for u in $U1 $U2 $U3; do id "$u" >/dev/null 2>&1 || useradd -M -d "$T/home-$u" -s /bin/bash "$u"; done
usermod -aG $G $U1; usermod -aG $G $U2               # U3 is not in the group

cp -r "$ROOT" "$T/repo"; chmod -R a+rX "$T/repo"
mkdir "$T/scratch"; chgrp $G "$T/scratch"; chmod 3770 "$T/scratch"   # like /hpc/home/scratch
S=$T/scratch/repairbench-java
as() { local u=$1; shift; runuser -u "$u" -- bash -c "cd '$T/repo' && export HOME='$T/home-$u' RB_WORK='$T/work-$u' OUT='$T/work-$u/out' RB_SHARED='$S' && $*"; }
pass() { echo "  ok    $*"; }
die()  { echo "  FAIL  $*"; exit 1; }
for u in $U1 $U2 $U3; do mkdir -p "$T/home-$u" "$T/work-$u"; chown "$u" "$T/home-$u" "$T/work-$u"; done

echo "setup by $U1"
as $U1 "scripts/setup_shared.sh '$S'" >/dev/null || die "setup_shared.sh as $U1"
[[ $(stat -c %a "$S/runs") == 3770 && $(stat -c %G "$S/runs") == "$G" ]] && pass "runs/ is 3770, group $G" || die "runs/ mode"
as $U2 "scripts/setup_shared.sh '$S'" >/dev/null && pass "$U2 re-running setup only checks" || die "setup as $U2"

echo "env.sh points the big folders at the shared one"
OUT2=$(as $U2 "source scripts/env.sh >/dev/null && echo \$MODELS_ROOT \$IMAGES \$RUNS \$(umask)")
[[ $OUT2 == "$S/models $S/images $S/runs 0027" ]] && pass "MODELS_ROOT, IMAGES, RUNS shared; umask 0027" || die "env.sh: $OUT2"
OUT3=$(as $U3 "export RUNS='$T/work-$U3/runs'; source scripts/env.sh 2>&1 >/dev/null; echo \${RB_SHARED:-none} \$RUNS")
[[ $OUT3 == *"none $T/work-$U3/runs"* ]] && pass "outsider $U3: warned, falls back to own folders" || die "outsider env: $OUT3"

echo "results: own experiments, readable by the group, protected from others"
as $U1 "source scripts/env.sh >/dev/null && mkdir -p \$RUNS/exp1/m && echo r > \$RUNS/exp1/m/result.json"
as $U2 "cat '$S/runs/exp1/m/result.json'" >/dev/null && pass "$U2 reads $U1's results" || die "group read"
as $U2 "rm -rf '$S/runs/exp1'" 2>/dev/null || true; [[ -f $S/runs/exp1/m/result.json ]] && pass "$U2 cannot delete $U1's experiment" || die "deleted"
as $U2 "mv '$S/runs/exp1' '$S/runs/x'" 2>/dev/null && die "$U2 renamed it" || pass "$U2 cannot rename it"
as $U2 "echo x > '$S/runs/exp1/m/result.json'" 2>/dev/null && die "$U2 overwrote it" || pass "$U2 cannot overwrite it"
as $U3 "ls '$S/runs'" >/dev/null 2>&1 && die "outsider reads" || pass "outsider $U3 cannot even list it"
echo t > "$T/tasks.txt"; chmod 644 "$T/tasks.txt"
MSG=$(as $U2 "source scripts/env.sh >/dev/null && RB_EXPERIMENT=exp1 scripts/run_experiment.sh m /none '$T/tasks.txt' \$OUT \$IMAGES \$CACHE \$RUNS" 2>&1 || true)
[[ $MSG == *"already belongs to $U1"* ]] && pass "$U2 reusing $U1's experiment name: clear message" || die "run_experiment: $MSG"

echo "model weights: downloaded once"
as $U1 "source scripts/env.sh >/dev/null && mkdir -p \$MODELS_ROOT/qwen3-coder-next && echo w > \$MODELS_ROOT/qwen3-coder-next/config.json && echo h > \$MODELS_ROOT/qwen3-coder-next.sha256"
MSG=$(as $U2 "source scripts/env.sh >/dev/null && scripts/download_models.sh qwen3-coder-next" 2>&1)
[[ $MSG == *"already downloaded by $U1; skipping"* ]] && pass "$U2 skips the model $U1 downloaded" || die "download: $MSG"

echo "images: shared, not deletable by others"
as $U1 "source scripts/env.sh >/dev/null && echo img > \$IMAGES/tasks/a.sif"
as $U2 "rm -f '$S/images/tasks/a.sif'" 2>/dev/null || true; [[ -f $S/images/tasks/a.sif ]] && pass "$U2 cannot delete $U1's image" || die "image deleted"

echo "shared Maven cache: everyone can add"
as $U1 "umask 0007 && mkdir -p '$S/cache/m2/org/junit' && echo j > '$S/cache/m2/org/junit/a.jar'"
as $U2 "umask 0007 && mkdir -p '$S/cache/m2/org/junit/b' && echo k > '$S/cache/m2/org/junit/b/b.jar'" && pass "$U2 adds to the cache folder $U1 created" || die "cache add"

echo "moving an existing work folder in"
as $U2 "mkdir -p \$RB_WORK/models/devstral-small \$RB_WORK/images/tasks && echo d > \$RB_WORK/models/devstral-small/config.json && echo i > \$RB_WORK/images/tasks/a.sif && echo i2 > \$RB_WORK/images/tasks/b.sif"
MSG=$(as $U2 "scripts/setup_shared.sh '$S' --move \$RB_WORK")
[[ -f $S/models/devstral-small/config.json && $(stat -c %U "$S/models/devstral-small") == "$U2" ]] && pass "$U2's model moved in" || die "move model: $MSG"
[[ $(cat "$S/images/tasks/a.sif") == img && -f $S/images/tasks/b.sif ]] && pass "existing image kept, new one moved" || die "move images"
as $U1 "cat '$S/models/devstral-small/config.json'" >/dev/null && pass "$U1 reads the moved model" || die "moved not readable"

echo "ALL SHARED-STORAGE CHECKS PASSED"
