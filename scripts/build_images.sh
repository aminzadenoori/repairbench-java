#!/usr/bin/env bash
# Build every image the tasks need and record their SHA256 (network node).
#   scripts/build_images.sh <images_dir> [out_dir]
# Builds java-ubuntu22.04-jdk{8,11,17,21}.sif and vllm.sif. With out_dir, also writes the
# hashes into out_dir/configs/*.json ("expected_image_sha256").
# Override the list with JDKS="8 11"; skip vLLM with SKIP_VLLM=1.
set -euo pipefail
IMAGES=${1:?usage: build_images.sh <images_dir> [out_dir]}
OUT=${2:-}
HERE=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$IMAGES"
JDKS=${JDKS:-"8 11 17 21"}
BUILD=(apptainer build --fakeroot --force)

for J in $JDKS; do
  IMG="$IMAGES/java-ubuntu22.04-jdk$J.sif"
  echo "== building $IMG"
  "${BUILD[@]}" --build-arg "JDK=$J" "$IMG" "$HERE/environments/java.def"
  sha256sum "$IMG" | cut -d' ' -f1 > "$IMG.sha256"
done
if [[ -z ${SKIP_VLLM:-} ]]; then
  echo "== building $IMAGES/vllm.sif"
  "${BUILD[@]}" --build-arg "VLLM_VERSION=${VLLM_VERSION:-v0.11.0}" "$IMAGES/vllm.sif" "$HERE/environments/vllm.def"
  sha256sum "$IMAGES/vllm.sif" | cut -d' ' -f1 > "$IMAGES/vllm.sif.sha256"
fi

if [[ -n $OUT ]]; then
  python3 -I - "$OUT/configs" "$IMAGES" <<'EOF'
import json, sys
from pathlib import Path
cdir, images = Path(sys.argv[1]), Path(sys.argv[2])
for f in sorted(cdir.glob("*.json")):
    cfg = json.loads(f.read_text())
    img = images / Path(cfg["image"]).name
    sha = img.with_name(img.name + ".sha256")
    if sha.exists():
        cfg["expected_image_sha256"] = sha.read_text().strip()
        f.write_text(json.dumps(cfg, indent=2) + "\n")
        print(f"pinned {f.name} -> {img.name}")
    else:
        print(f"no image for {f.name} ({img.name})")
EOF
fi
echo "done. Copy the .sha256 values into docs/RUNTIME_RELEASES.md of the main repo."
