# Default locations. Source it once per shell:   source scripts/env.sh
#
# For a first try everything lives in ./work inside the repository. To put the large files
# (images, caches, model weights) somewhere else later, set RB_WORK before sourcing:
#   RB_WORK=/big/disk/rb source scripts/env.sh
# Any single variable that is already set is kept as it is.
# shellcheck shell=bash
RB_REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export RB_REPO
export RB_WORK=${RB_WORK:-$RB_REPO/work}
export IMAGES=${IMAGES:-$RB_WORK/images}                 # .sif images
export CACHE=${CACHE:-$RB_WORK/cache}                    # Maven/Gradle caches
export MODELS_ROOT=${MODELS_ROOT:-$RB_WORK/models}       # model weights
export VLLM_SIF=${VLLM_SIF:-$IMAGES/vllm.sif}
export APPTAINER_CACHEDIR=${APPTAINER_CACHEDIR:-$RB_WORK/apptainer-cache}
export APPTAINER_TMPDIR=${APPTAINER_TMPDIR:-$RB_WORK/tmp}
export OUT=${OUT:-$RB_REPO/out}                          # task folders
export RUNS=${RUNS:-$RB_REPO/runs}                       # agent runs and results
mkdir -p "$IMAGES" "$CACHE" "$MODELS_ROOT" "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"
echo "RB_WORK=$RB_WORK  (images, caches, models)   OUT=$OUT   RUNS=$RUNS"
