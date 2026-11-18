# Default locations. Source it once per shell:   source scripts/env.sh
#
# For a first try everything lives in ./work inside the repository. To put the large files
# (images, caches, model weights) somewhere else later, set RB_WORK before sourcing:
#   RB_WORK=/big/disk/rb source scripts/env.sh
# A variable that is already set is kept, unless its folder can't be created; then it is
# reset to the default and a warning says so (e.g. an old export to a missing /scratch).
#
# Group-shared storage (the Foundry's /hpc/home/scratch): set RB_SHARED before sourcing,
#   export RB_SHARED=/hpc/home/scratch/repairbench-java      (created by scripts/setup_shared.sh)
# Then model weights, task images, caches and results (RUNS) live there, once for everybody,
# and files you create are readable by the group (umask 0027). OUT, logs and Apptainer's own
# cache stay in your clone.
# shellcheck shell=bash
RB_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export RB_REPO

_rb_dir() {  # _rb_dir <VAR> <default> : keep $VAR if usable, else use the default
  local name=$1 default=$2 value=${!1:-}
  if [[ -n $value ]] && ! mkdir -p "$value" 2>/dev/null; then
    echo "warning: $name=$value can't be created; using $default instead" >&2
    value=""
  fi
  value=${value:-$default}
  mkdir -p "$value" || { echo "error: can't create $value for $name" >&2; return 1; }
  export "$name=$value"
}

_rb_dir RB_WORK "$RB_REPO/work"
_RB_BIG=$RB_WORK                                   # where images, caches and weights go
_RB_RUNS=$RB_REPO/runs
if [[ -n ${RB_SHARED:-} ]]; then
  if [[ -f $RB_SHARED/.rb-shared && -w $RB_SHARED/runs ]]; then
    _RB_BIG=$RB_SHARED; _RB_RUNS=$RB_SHARED/runs
    umask 0027                                     # what you create: group can read, others nothing
    export RB_SHARED
  else
    echo "warning: RB_SHARED=$RB_SHARED is not set up (or not writable for you);" \
         "run scripts/setup_shared.sh $RB_SHARED. Using $RB_WORK for now." >&2
    unset RB_SHARED
  fi
fi
_rb_dir IMAGES "$_RB_BIG/images"                   # .sif images
_rb_dir CACHE "$_RB_BIG/cache"                     # Maven/Gradle caches
_rb_dir MODELS_ROOT "$_RB_BIG/models"              # model weights
_rb_dir APPTAINER_CACHEDIR "$RB_WORK/apptainer-cache"
# Apptainer unpacks images here while pulling. Keep it on a LOCAL disk: network file
# systems (e.g. some home/NFS/SMB mounts) reject file names such as ":.1.gz" that real
# images contain, and the pull then fails with "invalid argument".
_rb_dir APPTAINER_TMPDIR "${TMPDIR:-/tmp}/${USER:-rb}-rb-apptainer-tmp"
_rb_dir OUT "$RB_REPO/out"                         # task folders
_rb_dir RUNS "$_RB_RUNS"                           # experiments: agent runs and results
export VLLM_SIF=${VLLM_SIF:-$IMAGES/vllm.sif}
unset -f _rb_dir
unset _RB_BIG _RB_RUNS
if [[ -n ${RB_SHARED:-} ]]; then
  echo "RB_SHARED=$RB_SHARED  (images, caches, models, runs: shared with the group)   OUT=$OUT"
else
  echo "RB_WORK=$RB_WORK  (images, caches, models)   OUT=$OUT   RUNS=$RUNS"
fi
