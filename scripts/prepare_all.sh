#!/usr/bin/env bash
# One command for the network-side preparation of ALL tasks in data/java.csv.
#   scripts/prepare_all.sh [out_dir] [owner/repo ...]
# Steps: convert CSV -> task folders; check/repair patches at each base commit;
# build one history-limited repo.bundle per task. Dependency warm-up and validation
# are separate (they need the JDK images): see README.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-out}; shift || true
python3 -I scripts/convert_tddbench.py --csv data/java.csv --out "$OUT"
python3 -I scripts/normalize_patches.py "$OUT" mirrors "$@"
if [[ $# -eq 0 ]]; then
  scripts/make_bundles.sh "$OUT"
else
  for r in "$@"; do scripts/make_bundles.sh "$OUT" "$r"; done
fi
echo "ready: $OUT (see $OUT/SUMMARY.md and $OUT/manifest.json)"
