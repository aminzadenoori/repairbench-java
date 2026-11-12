#!/usr/bin/env bash
# Check everything the pipeline needs, before the first run.
#   source scripts/env.sh && scripts/check_setup.sh          (or: bash scripts/check_setup.sh)
#   QUICK=1  skips the checks that pull a small test image with Apptainer
#
# Prints OK / WARN / FAIL per check with a hint, then which stages are ready.
# Exit code 0 if nothing FAILed.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
[[ -n ${RB_WORK:-} ]] || . "$REPO/scripts/env.sh" >/dev/null
OKS=0; WARNS=0; FAILS=0
declare -A READY

ok()   { printf '  [ OK ] %s\n' "$1"; OKS=$((OKS + 1)); }
warn() { printf '  [WARN] %s\n' "$1"; [[ -n ${2:-} ]] && printf '         -> %s\n' "$2"; WARNS=$((WARNS + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; [[ -n ${2:-} ]] && printf '         -> %s\n' "$2"; FAILS=$((FAILS + 1)); }
need() { READY[$1]="${READY[$1]:-yes}"; [[ $2 == ok ]] || READY[$1]=no; }   # need <stage> ok|no
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n%s\n' "$1"; }
vge() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1) == "$2" ]]; }  # vge <have> <min>

# -------------------------------------------------------------------------- basics
section "1. Basics"
if have git; then ok "git $(git --version | awk '{print $3}')"; need tasks ok; else fail "git missing" "install git or load its module"; need tasks no; fi
PYV=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 0)
if vge "$PYV" 3.9; then ok "python3 $PYV (standard library only, no pip packages needed)"; need tasks ok
else fail "python3 >= 3.9 not found (got $PYV)" "load a newer Python module"; need tasks no; fi
BAD=$(cd "$REPO" && for f in command_run_gold.sh scripts/*.sh scripts/*.py agent/agent.py tests/e2e_fake.sh tests/fake/apptainer tests/fake/bin/mvn tests/fake/model_server.py; do [[ -x $f ]] || echo "$f"; done)
if [[ -z $BAD ]]; then ok "scripts are executable"
else fail "$(echo "$BAD" | wc -l) scripts are not executable (lost on upload?)" \
  "cd $REPO && chmod +x command_run_gold.sh scripts/*.sh scripts/*.py agent/agent.py tests/e2e_fake.sh tests/fake/apptainer tests/fake/bin/mvn tests/fake/model_server.py"
  need tasks no; fi
[[ -s $REPO/data/java.csv ]] && ok "dataset data/java.csv present" || { fail "data/java.csv missing"; need tasks no; }
FREE=$(python3 -c 'import shutil,sys; print(shutil.disk_usage(sys.argv[1]).free // 2**30)' "$RB_WORK" 2>/dev/null || echo 0)
if (( FREE >= 300 )); then ok "free disk at $RB_WORK: ${FREE} GB"
elif (( FREE >= 10 )); then warn "free disk at $RB_WORK: ${FREE} GB (enough for a first try with a few tasks)" \
  "all 250 frozen images + the 4 models need several hundred GB; later set RB_WORK to a bigger disk"
else fail "only ${FREE} GB free at $RB_WORK" "set RB_WORK to a disk with more space and re-source scripts/env.sh"; fi
if have unshare && unshare -rn true 2>/dev/null; then ok "user namespaces allowed (tests/e2e_fake.sh can cut the network)"
else warn "user namespaces not allowed for this user" "tests/e2e_fake.sh will run, but its leak self-test check fails on purpose"; fi

# -------------------------------------------------------------------------- network
section "2. Network (Stage 1 needs it; Stages 2-3 run offline)"
read -r POLY_ID MSWE_IMG < <(python3 -I - "$REPO/data/java.csv" <<'EOF'
import csv, sys
csv.field_size_limit(sys.maxsize)
poly = msw = ""
for r in csv.DictReader(open(sys.argv[1], newline="", encoding="utf-8")):
    img = r.get("image_name") or ""
    if img.startswith("mswebench") and not msw: msw = img
    if not img.startswith("mswebench") and not poly: poly = r["instance_id"]
print(poly or "google__gson-2337", msw or "mswebench/fasterxml_m_jackson-databind:pr-4131")
EOF
)
NET=$(python3 -I - "$POLY_ID" "$MSWE_IMG" <<'EOF'
import json, sys, urllib.request, urllib.error
poly, msw = sys.argv[1], sys.argv[2]
ACCEPT = ", ".join(["application/vnd.oci.image.index.v1+json", "application/vnd.oci.image.manifest.v1+json",
                    "application/vnd.docker.distribution.manifest.list.v2+json",
                    "application/vnd.docker.distribution.manifest.v2+json"])
def get(url, headers=None, method="GET"):
    req = urllib.request.Request(url, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read() if method == "GET" else b""
    except urllib.error.HTTPError as e:
        return e.code, b""
    except Exception as e:
        return None, str(e).encode()
def manifest(token_url, manifest_url):
    st, body = get(token_url)
    if st != 200:
        return f"token {st or body.decode()[:80]}"
    tok = json.loads(body).get("token") or json.loads(body).get("access_token")
    st, body = get(manifest_url, {"Authorization": f"Bearer {tok}", "Accept": ACCEPT}, "HEAD")
    return "ok" if st == 200 else f"manifest {st or body.decode()[:80]}"
res = {}
st, _ = get("https://github.com/google/gson.git/info/refs?service=git-upload-pack")
res["github"] = "ok" if st == 200 else (str(st) if st else _.decode()[:90])
repo = f"timesler/swe-polybench.eval.x86_64.{poly.lower()}"
res["ghcr"] = manifest(f"https://ghcr.io/token?scope=repository:{repo}:pull&service=ghcr.io",
                       f"https://ghcr.io/v2/{repo}/manifests/v1.1")
if res["ghcr"] != "ok":
    alt = manifest(f"https://ghcr.io/token?scope=repository:{repo}:pull&service=ghcr.io",
                   f"https://ghcr.io/v2/{repo}/manifests/latest")
    if alt == "ok": res["ghcr"] = "ok (only :latest)"
name, tag = msw.rsplit(":", 1)
res["dockerhub"] = manifest(f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{name}:pull",
                            f"https://registry-1.docker.io/v2/{name}/manifests/{tag}")
for m in ["Qwen/Qwen3-Coder-Next", "openai/gpt-oss-120b", "mistralai/Devstral-Small-2507", "zai-org/GLM-4.7-Flash"]:
    st, _ = get(f"https://huggingface.co/api/models/{m}")
    res["hf:" + m] = "ok" if st == 200 else (str(st) if st else _.decode()[:90])
for k, u in {"maven": "https://repo1.maven.org/maven2/", "adoptium": "https://packages.adoptium.net/",
             "apache": "https://archive.apache.org/dist/maven/maven-3/", "gradle": "https://services.gradle.org/distributions/"}.items():
    st, body = get(u, method="GET")
    res[k] = "ok" if st and st < 400 else (str(st) if st else body.decode()[:90])
print(json.dumps(res))
EOF
)
net() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], "?"))' "$NET" "$1"; }
[[ $(net github) == ok ]] && { ok "GitHub (task repositories)"; need tasks ok; } || { fail "GitHub not reachable ($(net github))" "needed to clone the 13 repositories; check proxy settings (HTTPS_PROXY)"; need tasks no; }
G=$(net ghcr); [[ $G == ok* ]] && { ok "GHCR: SWE-PolyBench image for $POLY_ID $( [[ $G == ok ]] && echo '(:v1.1)' || echo '(:latest only)')"; need frozen ok; } \
  || { fail "GHCR (ghcr.io) image for $POLY_ID not reachable: $G" "needed for the 157 SWE-PolyBench tasks; ask whether ghcr.io is allowed from this node"; need frozen no; }
D=$(net dockerhub); [[ $D == ok ]] && { ok "Docker Hub: Multi-SWE-bench image $MSWE_IMG"; need frozen ok; } \
  || { fail "Docker Hub image $MSWE_IMG not reachable: $D" "needed for the 93 Multi-SWE-bench tasks; ask whether registry-1.docker.io is allowed"; need frozen no; }
for m in Qwen/Qwen3-Coder-Next openai/gpt-oss-120b mistralai/Devstral-Small-2507 zai-org/GLM-4.7-Flash; do
  S=$(net "hf:$m")
  case $S in
    ok) ok "Hugging Face: $m"; need models ok ;;
    401|403) warn "Hugging Face: $m needs a login (HTTP $S)" "accept its licence on the website, then: hf auth login (or export HF_TOKEN=...)"; need models no ;;
    *) fail "Hugging Face: $m not reachable ($S)" "needed once to download the weights"; need models no ;;
  esac
done
for k in maven adoptium apache gradle; do
  [[ $(net $k) == ok ]] && { ok "$k (only for the 'built' runtime)"; need built ok; } || { warn "$k not reachable ($(net $k))" "only matters for RB_RUNTIME=built (our own JDK images); the frozen runtime does not need it"; need built no; }
done

# -------------------------------------------------------------------------- apptainer
section "3. Apptainer"
if have apptainer; then
  AV=$(apptainer --version | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
  if vge "$AV" 1.2; then ok "apptainer $AV"; need frozen ok; need built ok
  elif vge "$AV" 1.1; then warn "apptainer $AV (1.2+ needed to build our images with --build-arg)" "frozen runtime is fine"; need frozen ok; need built no
  else fail "apptainer $AV is too old" "need 1.1+ (1.2+ for building images)"; need frozen no; need built no; fi
  if [[ -z ${QUICK:-} ]]; then
    T=$(mktemp -d "$APPTAINER_TMPDIR/check-XXXX"); SIF=$IMAGES/check-busybox.sif
    if [[ -s $SIF ]] || apptainer pull --force "$SIF" docker://busybox:1.36 >"$T/pull.log" 2>&1; then
      ok "apptainer pull from Docker Hub works (test image busybox)"
      if apptainer exec --containall --no-home --bind "$T:/work" "$SIF" sh -c 'echo hi > /work/x' 2>"$T/e1" && [[ -f $T/x ]]; then
        ok "apptainer exec with --containall and a bind mount"; need run ok
      else fail "apptainer exec with a bind mount failed: $(tail -1 "$T/e1")"; need run no; fi
      if apptainer exec --net --network none --containall --no-home "$SIF" sh -c 'wget -q -T 5 -O /dev/null http://example.com' >/dev/null 2>"$T/e2"; then
        fail "--net --network none did NOT cut the network" "the agent sandbox would not be sealed; ask your admins"; need run no
      elif grep -qiE 'not permitted|not allowed|permission|requires|unknown|setuid' "$T/e2"; then
        fail "--net --network none is not allowed: $(tail -1 "$T/e2")" "ask admins to allow 'none' in apptainer.conf (allow net networks) or user namespaces; Stages 2-3 need it"; need run no
      else ok "--net --network none works and blocks the network (needed for Stages 2-3)"; need run ok; fi
      if apptainer instance start --net --network none --containall --no-home "$SIF" rbcheck >/dev/null 2>"$T/e3"; then
        apptainer exec instance://rbcheck true && ok "apptainer instances work (the agent runs in one)"; need run ok
        apptainer instance stop rbcheck >/dev/null 2>&1
      else fail "apptainer instance start failed: $(tail -1 "$T/e3")"; need run no; fi
      if apptainer exec --fakeroot "$SIF" true >/dev/null 2>&1; then ok "--fakeroot works (image builds, cache extraction from frozen images)"; need built ok
      else warn "--fakeroot not available" "frozen runtime still works if the images' /root is readable; building our own images (built runtime) needs --fakeroot or a build node"; need built no; fi
    else
      fail "apptainer pull of docker://busybox failed: $(tail -1 "$T/pull.log")" "check Docker Hub access and APPTAINER_CACHEDIR/TMPDIR"; need frozen no; need run no
    fi
    rm -rf "$T"
  else warn "QUICK=1: Apptainer runtime checks skipped"; fi
else
  fail "apptainer not found" "module load apptainer (or singularity), or ask your admins"; need frozen no; need built no; need run no
fi

# -------------------------------------------------------------------------- models / GPU
section "4. Models and GPU (only on the node that serves the model)"
if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then ok "GPU: $(nvidia-smi -L | head -1 | cut -c1-70) ($(nvidia-smi -L | wc -l) total)"; need gpu ok
else warn "no GPU visible on this node" "fine on a login node; Stage 2 must run where nvidia-smi works"; need gpu no; fi
if have hf || have huggingface-cli; then ok "Hugging Face CLI installed"; else warn "Hugging Face CLI missing" "pip install -U 'huggingface_hub[cli]'  (only for scripts/download_models.sh)"; need models no; fi
[[ -s $VLLM_SIF ]] && ok "vLLM image at $VLLM_SIF" || warn "no vLLM image yet" "apptainer build --fakeroot --build-arg VLLM_VERSION=v0.11.0 \"\$VLLM_SIF\" environments/vllm.def"
N=$(find "$MODELS_ROOT" -maxdepth 2 -name config.json 2>/dev/null | wc -l)
(( N > 0 )) && ok "$N model(s) downloaded in $MODELS_ROOT" || warn "no models downloaded yet" "scripts/download_models.sh"
have sbatch && ok "Slurm available (sbatch) for cluster jobs" || warn "no sbatch: run jobs directly"

# -------------------------------------------------------------------------- summary
section "Summary: $OKS ok, $WARNS warnings, $FAILS failures"
r() { [[ ${READY[$1]:-no} == yes ]] && echo "ready" || echo "NOT ready"; }
printf '  Prepare tasks        (scripts/prepare_all.sh)        %s\n' "$(r tasks)"
printf '  Gold check, frozen   (scripts/run_gold.sh)           %s\n' "$( [[ $(r tasks) == ready && $(r frozen) == ready && $(r run) == ready ]] && echo ready || echo 'NOT ready')"
printf '  Built runtime        (scripts/build_images.sh)       %s\n' "$( [[ $(r built) == ready ]] && echo ready || echo 'not ready (optional)')"
printf '  Agent + evaluation   (scripts/run_experiment.sh)     %s\n' "$( [[ $(r run) == ready && $(r gpu) == ready ]] && echo ready || echo 'NOT ready here (needs a GPU node with the checks above passing)')"
printf '  Model download       (scripts/download_models.sh)    %s\n' "$(r models)"
(( FAILS == 0 ))
