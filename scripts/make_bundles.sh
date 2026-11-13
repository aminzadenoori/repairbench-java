#!/usr/bin/env bash
# Create repo.bundle for every task: history up to base_commit only, no remote.
# Needs network to GitHub (run on a login/network node). Safe to re-run.
#
#   scripts/make_bundles.sh <out_dir> [repo-filter]
#   scripts/make_bundles.sh out google/gson
set -euo pipefail
OUT=${1:?usage: make_bundles.sh <out_dir> [owner/repo]}
FILTER=${2:-}
OUT=$(cd "$OUT" && pwd)
# Full (not blob-filtered) mirrors: a bundle needs every object.
MIRRORS=${MIRRORS:-$(pwd)/mirrors-full}
mkdir -p "$MIRRORS"

python3 -I - "$OUT/manifest.json" "$FILTER" <<'EOF' |
import json, sys
m = json.load(open(sys.argv[1])); f = sys.argv[2]
for t in m:
    if not f or t["repository"] == f:
        print(t["repository"], t["task_dir"])
EOF
while read -r REPO TASK_DIR; do
  DIR="$OUT/$TASK_DIR"
  [[ -s "$DIR/repo.bundle" ]] && continue
  MIRROR="$MIRRORS/${REPO//\//__}.git"
  if [[ ! -d "$MIRROR" ]]; then
    echo "cloning $REPO"
    git clone --quiet --bare "https://github.com/$REPO.git" "$MIRROR"
  fi
  BASE=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["base_commit"])' "$DIR/metadata.json")
  if ! git -C "$MIRROR" cat-file -e "$BASE^{commit}" 2>/dev/null; then
    git -C "$MIRROR" fetch --quiet origin "$BASE" || { echo "MISSING $BASE for $TASK_DIR" >&2; continue; }
  fi
  # A throwaway ref at the base commit: the bundle then holds only base and its ancestors.
  git -C "$MIRROR" update-ref refs/heads/repairbench-base "$BASE"
  git -C "$MIRROR" bundle create --quiet "$DIR/repo.bundle.tmp" repairbench-base
  mv "$DIR/repo.bundle.tmp" "$DIR/repo.bundle"
  git -C "$MIRROR" update-ref -d refs/heads/repairbench-base
  echo "bundled $TASK_DIR"
done
