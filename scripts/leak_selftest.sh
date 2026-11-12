#!/usr/bin/env bash
# Prove that the agent's sandbox is sealed BEFORE the model gets it.
#   scripts/leak_selftest.sh <out.json> <history: none|base> <hidden_path|""> -- <exec prefix...>
# <exec prefix> runs one command in the sandbox, e.g.
#   apptainer exec --pwd /work/repo --env ... instance://rb_xxx
# Every network probe must FAIL; the workspace must have no git remote (and a single commit
# for history "none"); the frozen image's own repo copy (with its git history) must be
# hidden. Exit 0 only if everything holds.
set -uo pipefail
OUT=${1:?out.json}; HISTORY=${2:?history}; HIDDEN=${3-}; shift 3
[[ ${1:-} == -- ]] && shift
EXEC=("$@"); [[ ${#EXEC[@]} -gt 0 ]] || { echo "usage: ... -- <exec prefix>" >&2; exit 2; }

declare -A PROBES=(
  [tcp_maven_central]="python3 -c \"import socket; socket.create_connection(('repo1.maven.org', 443), 10)\" || (exec 3<>/dev/tcp/repo1.maven.org/443)"
  [tcp_github_ip]="(exec 3<>/dev/tcp/140.82.112.3/443)"
  [dns_github]="getent hosts github.com"
  [https_curl]="curl -sSf --max-time 10 https://github.com"
  [maven_online_download]="mvn -B -q -Dmaven.repo.local=/tmp/m2probe dependency:get -Dartifact=junit:junit:4.13.2"
  [git_fetch]="git fetch https://github.com/google/gson.git"
)
[[ -n $HIDDEN ]] && PROBES[image_repo_copy_hidden]="test -e '$HIDDEN/.git' || test -e '$HIDDEN/pom.xml' || test -e '$HIDDEN/build.gradle'"

TMP=$(mktemp)
for name in "${!PROBES[@]}"; do
  # MAVEN_ARGS is cleared so the Maven probe really tries to go online.
  timeout 60 "${EXEC[@]}" bash -lc "unset MAVEN_ARGS; timeout 30 ${PROBES[$name]}" >/dev/null 2>&1
  printf '%s\t%s\t%s\n' "$name" "$?" "${PROBES[$name]}" >> "$TMP"
done
REMOTES=$("${EXEC[@]}" git remote 2>/dev/null | wc -l)
COMMITS=$("${EXEC[@]}" git rev-list --all --count 2>/dev/null || echo "?")

python3 -I - "$TMP" "$OUT" "$HISTORY" "$REMOTES" "$COMMITS" <<'EOF'
import json, sys
tmp, out, history, remotes, commits = sys.argv[1:6]
probes = {}
for line in open(tmp):
    name, rc, cmd = line.rstrip("\n").split("\t", 2)
    probes[name] = {"command": cmd, "exit_code": int(rc), "sealed": int(rc) != 0}
ok = all(p["sealed"] for p in probes.values()) and int(remotes) == 0
if history == "none":
    ok = ok and commits.strip() == "1"
res = {"passed": ok, "history_profile": history, "git_remotes": int(remotes),
       "git_commits": commits.strip(), "probes": probes}
json.dump(res, open(out, "w"), indent=1)
print("leak self-test", "PASSED" if ok else "FAILED", "->", out)
sys.exit(0 if ok else 1)
EOF
rc=$?; rm -f "$TMP"; exit $rc
