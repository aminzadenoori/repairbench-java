#!/usr/bin/env bash
# Runs INSIDE the sealed agent container (apptainer exec ... instance://rb_x), started by
# scripts/run_agent.sh. Starts the forwarder, waits until it listens, then runs the agent
# loop in the same container: its tool commands run locally (no exec prefix).
#
#   in_container.sh <model-socket> <port> -- <agent.py arguments...>
# Exit 97: the forwarder could not start (run_agent.sh then falls back to the host agent).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SOCK=${1:?socket}; PORT=${2:?port}; shift 2
[[ ${1:-} == -- ]] && shift

python3 -I "$HERE/uds_proxy.py" "$SOCK" "$PORT" &
PROXY=$!
trap 'kill $PROXY 2>/dev/null || true' EXIT

up=0
for _ in $(seq 1 50); do
  kill -0 $PROXY 2>/dev/null || break
  if python3 -I -c "import socket,sys; socket.create_connection(('127.0.0.1', int(sys.argv[1])), 1)" "$PORT" 2>/dev/null; then
    up=1; break
  fi
  sleep 0.2
done
[[ $up == 1 ]] || { echo "forwarder did not start on 127.0.0.1:$PORT" >&2; exit 97; }

python3 -I "$HERE/agent.py" --base-url "http://127.0.0.1:$PORT/v1" --exec-prefix '[]' "$@"
