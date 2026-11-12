#!/usr/bin/env bash
# Frozen runtime, Stage 1 (network ON): pull each task's prebuilt image as an Apptainer
# .sif and extract its Maven/Gradle caches. No Docker daemon is involved: Apptainer reads
# the images straight from the registries (GHCR for SWE-PolyBench, Docker Hub for
# Multi-SWE-bench).
#
#   scripts/pull_task_images.sh <out_dir> <images_dir> <cache_dir> [owner/repo | instance_id ...]
#
# Results: <images>/tasks/<instance_id>.sif (+ .sha256)
#          <cache>/tasks/<instance_id>/{m2,gradle}   (copied from the image's /root)
# Then run validation etc. with RB_RUNTIME=frozen. Images are large (often 1-5 GB each);
# set APPTAINER_CACHEDIR / APPTAINER_TMPDIR to scratch storage.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
OUT=$(cd "${1:?out_dir}" && pwd); IMAGES=${2:?images_dir}; CACHE=${3:?cache_dir}; shift 3
mkdir -p "$IMAGES/tasks" "$CACHE/tasks"; IMAGES=$(cd "$IMAGES" && pwd); CACHE=$(cd "$CACHE" && pwd)
FAILED=0

TASKS=$(python3 -I - "$OUT/manifest.json" "$@" <<'EOF'
import json, sys
only = set(sys.argv[2:])
for t in json.load(open(sys.argv[1])):
    if not only or t["repository"] in only or t["instance_id"] in only:
        print(t["task_dir"])
EOF
)
while read -r TD; do
  [[ -n $TD ]] || continue
  T="$OUT/$TD"; ID=$(task_id "$T")
  REF=$(meta "$T" 'd["environment"].get("frozen_image")')
  SIF="$IMAGES/tasks/$ID.sif"; C="$CACHE/tasks/$ID"
  if [[ ! -s $SIF ]]; then
    # SWE-PolyBench recommends its frozen :v1.1 tags; IBM's TDD-Bench harness pulls :latest.
    # Try the pinned tag first and record which one was used.
    PULLED=""; : > "$SIF.pull.log"
    for R in "$REF" "${REF%:v1.1}:latest"; do
      echo "pulling $R"
      echo "===== apptainer pull $R" >> "$SIF.pull.log"     # keep every attempt's output
      if apptainer pull --force "$SIF.tmp" "$R" </dev/null >>"$SIF.pull.log" 2>&1; then PULLED=$R; break; fi
      [[ $R == "${REF%:v1.1}:latest" || $REF != *:v1.1 ]] && break
    done
    if [[ -z $PULLED ]]; then
      echo "PULL FAILED $ID; last lines of $SIF.pull.log:"
      grep -E 'FATAL|ERROR|error|denied|space|quota' "$SIF.pull.log" | tail -n 6 | sed 's/^/    /'
      rm -f "$SIF.tmp"; FAILED=$((FAILED + 1)); continue
    fi
    echo "$PULLED" > "$SIF.source"
    mv "$SIF.tmp" "$SIF"; sha256sum "$SIF" | cut -d' ' -f1 > "$SIF.sha256"
  fi
  if [[ ! -f $C/.done ]]; then
    mkdir -p "$C"
    # Copy whatever caches the image built while it was created (as root). /root is often
    # mode 700, so read it with --fakeroot where allowed, else as the current user.
    EXTRACT='
      for d in /root/.m2/repository /home/*/.m2/repository; do
        [ -d "$d" ] && { mkdir -p /out/m2 && cp -r "$d/." /out/m2/; }; done
      for d in /root/.gradle /home/*/.gradle; do
        [ -d "$d" ] && { mkdir -p /out/gradle && cp -r "$d/caches" "$d/wrapper" /out/gradle/ 2>/dev/null; }; done
      true'
    apptainer exec --fakeroot --containall --no-home --bind "$C:/out" "$SIF" bash -c "$EXTRACT" </dev/null 2>/dev/null ||
      apptainer exec --containall --no-home --bind "$C:/out" "$SIF" bash -c "$EXTRACT" </dev/null
    [[ -d $C/m2 || -d $C/gradle ]] || echo "WARNING $ID: no Maven/Gradle cache found in the image (offline build will likely fail)"
    rm -rf "$C/gradle/caches"/*/*.lock 2>/dev/null || true
    touch "$C/.done"
    echo "ready $ID  ($(du -sh "$C" | cut -f1) of caches)"
  fi
done <<< "$TASKS"
(( FAILED == 0 )) || { echo "$FAILED image(s) failed to pull"; exit 1; }
