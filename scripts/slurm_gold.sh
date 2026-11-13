#!/bin/bash
# Gold check of all tasks as a Slurm array: one array element per instance, offline.
# Pull the images on the login node first (compute nodes may have no network):
#   scripts/pull_task_images.sh "$OUT" "$IMAGES" "$CACHE"
#   sbatch scripts/slurm_gold.sh                      # all 250, at most 20 at a time
#   sbatch --array=1-34 scripts/slurm_gold.sh         # e.g. only the first lines
# Element k runs line k of command_run_gold.sh. Finished instances are skipped.
#
#SBATCH --job-name=rb-gold
#SBATCH --partition=gpuq
#SBATCH --array=1-250%20
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --output=logs/%x-%A_%a.out
set -euo pipefail

command -v apptainer >/dev/null || { echo "apptainer not found on $(hostname)"; exit 1; }   # on the PATH, no module needed

cd "${SLURM_SUBMIT_DIR:-$HOME/repairbench-java}"
mkdir -p logs
source scripts/env.sh
export APPTAINER_TMPDIR=/tmp/$USER/apptainer-tmp && mkdir -p "$APPTAINER_TMPDIR"

K=${SLURM_ARRAY_TASK_ID:?run with sbatch --array}
ID=$(grep '^scripts/run_gold' command_run_gold.sh | sed -n "${K}p" | awk '{print $NF}')
[[ -n $ID ]] || { echo "no line $K in command_run_gold.sh"; exit 0; }
echo "array element $K -> $ID on $(hostname)"
scripts/run_gold.sh "$OUT" "$IMAGES" "$CACHE" "$ID"
