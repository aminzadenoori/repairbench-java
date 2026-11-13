# Default locations. Source it once per shell:   source scripts/env.sh
#
# For a first try everything lives in ./work inside the repository. To put the large files
# (images, caches, model weights) somewhere else later, set RB_WORK before sourcing:
#   RB_WORK=/big/disk/rb source scripts/env.sh
# A variable that is already set is kept, unless its folder can't be created; then it is
# reset to the default and a warning says so (e.g. an old export to a missing /scratch).
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
_rb_dir IMAGES "$RB_WORK/images"                   # .sif images
_rb_dir CACHE "$RB_WORK/cache"                     # Maven/Gradle caches
_rb_dir MODELS_ROOT "$RB_WORK/models"              # model weights
_rb_dir APPTAINER_CACHEDIR "$RB_WORK/apptainer-cache"
# Apptainer unpacks images here while pulling. Keep it on a LOCAL disk: network file
# systems (e.g. some home/NFS/SMB mounts) reject file names such as ":.1.gz" that real
# images contain, and the pull then fails with "invalid argument".
_rb_dir APPTAINER_TMPDIR "${TMPDIR:-/tmp}/${USER:-rb}-rb-apptainer-tmp"
_rb_dir OUT "$RB_REPO/out"                         # task folders
_rb_dir RUNS "$RB_REPO/runs"                       # agent runs and results
export VLLM_SIF=${VLLM_SIF:-$IMAGES/vllm.sif}
unset -f _rb_dir
echo "RB_WORK=$RB_WORK  (images, caches, models)   OUT=$OUT   RUNS=$RUNS"
