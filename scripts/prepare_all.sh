#!/usr/bin/env bash
# Network-side preparation of ALL tasks in data/java.csv (no images needed).
#   scripts/prepare_all.sh [out_dir] [owner/repo ...]
# 1. convert CSV -> task folders   2. check/repair patches at each base commit
# 3. infer a JDK where the CSV has none   4. one history-limited repo.bundle per task
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-out}; shift || true
python3 -I scripts/convert_tddbench.py --csv data/java.csv --out "$OUT"
python3 -I scripts/normalize_patches.py "$OUT" mirrors "$@"
python3 -I scripts/detect_jdk.py "$OUT" mirrors
if [[ $# -eq 0 ]]; then
  scripts/make_bundles.sh "$OUT"
else
  for r in "$@"; do scripts/make_bundles.sh "$OUT" "$r"; done
fi
echo "ready: $OUT (see $OUT/SUMMARY.md and $OUT/manifest.json)"
