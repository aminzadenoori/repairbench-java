#!/usr/bin/env bash
# Print a name nobody else will generate: <user>_<timestamp>_<random>,
# e.g. azadenoori_20261117-124530_3f9a1c2e. Used for vLLM sockets and instances, logs and
# experiment folders, so parallel runs (yours or other people's) never share a name.
set -euo pipefail
printf '%s_%s_%s\n' "${USER:-$(id -un)}" "$(date +%Y%m%d-%H%M%S)" \
  "$(python3 -I -c 'import uuid; print(uuid.uuid4().hex[:8])')"
