# TDD-Bench-Java → RepairBench

Runs open LLMs on the 250 Java bug-fix tasks of
[TDD-Bench-Java](https://github.com/IBM/TDD-Bench-Verified) the RepairBench way: the
model gets the issue and the code at the base commit and writes the **fix**; the PR's
tests stay hidden and decide whether it is resolved. This is the Java extension of the
C/C++ pipeline. **Everything runs in Apptainer; no Docker daemon is needed.**

```
Stage 1  Setup         network ON    task folders, images, dependency caches, gold check
Stage 2  Patch         network OFF   open LLM + agent in a sealed Apptainer instance
Stage 3  Evaluation    network OFF   candidate patch + hidden tests -> resolved or not
```

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [Run everything](#run-everything)
- [Where the results are](#where-the-results-are)
- [Troubleshooting](#troubleshooting)
- Further docs: [How it works](docs/PIPELINE.md) · [Reference](docs/REFERENCE.md) ·
  [Relation to TDD-Bench / SWE-PolyBench](docs/TDD_BENCH.md)

## Requirements

| Needed for | What |
|---|---|
| everything | Linux x86_64, bash, git, Python ≥ 3.9 (standard library only) |
| containers | Apptainer ≥ 1.2 (≥ 1.1 if you only use the frozen images) |
| Stage 1 | network to GitHub, `ghcr.io` and Docker Hub (images are pulled by Apptainer) |
| Stage 2 | GPU node; `huggingface_hub` CLI and network to Hugging Face once, for the weights |
| disk | a few GB per task for a first try; several hundred GB for all 250 tasks + 4 models |

`scripts/check_setup.sh` checks all of this for you (next section).

## Install

Nothing to compile or `pip install` for the pipeline itself.

```bash
git clone <your copy of this repo> repairbench-java && cd repairbench-java

source scripts/env.sh          # default paths: everything inside this folder (work/, out/, runs/)
scripts/check_setup.sh         # checks tools, permissions, disk, GitHub, GHCR, Docker Hub,
                               # Hugging Face, Apptainer (pull, bind, --network none, instances)
```

Run `source scripts/env.sh` in every new shell. The check prints `OK` / `WARN` / `FAIL`
with a hint for each problem, and at the end which stages are ready. Fix the `FAIL` lines
first. Typical ones:

| Check says | Do this |
|---|---|
| scripts are not executable | run the `chmod +x ...` line it prints (happens after a web upload) |
| GHCR / Docker Hub not reachable | ask whether `ghcr.io` and `registry-1.docker.io` are allowed from this node, or use another node |
| `--network none` not allowed | ask the admins to allow it (`allow net networks` in `apptainer.conf`); Stages 2–3 need it |
| apptainer not found | it should be on the PATH of every node (no module needed); check `command -v apptainer` on that node |
| Hugging Face needs a login | accept the model licence on the website, then `hf auth login` |

Large files go to `work/` inside the repo by default, which is fine for a first try. When
you scale up, put them on a bigger disk with `RB_WORK=/big/disk/rb source scripts/env.sh`.

Optional: `tests/e2e_fake.sh` runs the whole pipeline on a synthetic task with stand-ins
(no Apptainer, Maven or GPU needed) and ends with `ALL E2E CHECKS PASSED`.

## Quick start

One repository, one task, end to end. Run `source scripts/env.sh` first.

```bash
# 1. prepare the gson tasks (network node)
scripts/prepare_all.sh "$OUT" google/gson

# 2. gold check of one task: old code fails, real fix passes (pulls its image)
scripts/run_gold.sh "$OUT" "$IMAGES" "$CACHE" google__gson-2337
cat "$OUT/eval_logs/google__gson-2337_result.json"        # want "resolved": true

# 3. the model, once: weights + vLLM image, then start the server (GPU node)
pip install -U "huggingface_hub[cli]"
scripts/download_models.sh qwen3-coder-next
apptainer build --fakeroot --build-arg VLLM_VERSION=v0.11.0 "$VLLM_SIF" environments/vllm.def
# Model on several GPUs (qwen3-coder-next: 2)? Check once in a 2-GPU srun:
#   scripts/check_multi_gpu.sh qwen3-coder-next 2     # PASSED = every GPU holds its part
# vLLM has no network: it answers on a socket file. A unique name per server
# (<user>_<timestamp>_<random>) keeps your sessions and other people's apart.
SOCK=/tmp/$USER-rb/$(scripts/new_id.sh)/vllm.sock
scripts/serve_model.sh qwen3-coder-next "$SOCK" &           # instance rbvllm_<same id>
until curl -sf --unix-socket "$SOCK" http://localhost/v1/models >/dev/null; do sleep 10; done

# 4. agent + evaluation on that task (the agent runs inside the sealed task container and
#    reaches the socket through its own forwarder at 127.0.0.1:8000)
echo google__gson-2337 > one.txt
export RB_EXPERIMENT=try-gson                # results go to runs/try-gson/<model>/<task>/
RB_RUNTIME=frozen scripts/run_experiment.sh qwen3-coder-next "$SOCK" \
    one.txt "$OUT" "$IMAGES" "$CACHE" "$RUNS"
cat "$RUNS/try-gson/qwen3-coder-next/google__gson-2337/result.json"   # "outcome": "resolved" or not
```

## Run everything

```bash
source scripts/env.sh

# Stage 1: all 250 tasks
scripts/prepare_all.sh "$OUT"
./command_run_gold.sh                                     # gold check, one line per instance
python3 scripts/score_gold.py "$OUT"                      # -> out/validated_tasks.txt

# Stages 2 + 3: each of the four models, as one experiment
scripts/download_models.sh                                # all four, once
export RB_EXPERIMENT=main-history-none                    # one name for all four models
# on the cluster: one job per model, same experiment name (GPUs: see configs/models.json)
#   sbatch --export=ALL,MODEL=qwen3-coder-next --gres=gpu:h200:2 scripts/slurm_run_model.sh
#   sbatch --export=ALL,MODEL=gpt-oss-120b     --gres=gpu:h200:1 scripts/slurm_run_model.sh  ...
# or by hand on one GPU node, one round per model:
for M in qwen3-coder-next gpt-oss-120b devstral-small glm-4.7-flash; do
  SOCK=/tmp/$USER-rb/$(scripts/new_id.sh)/vllm.sock
  scripts/serve_model.sh "$M" "$SOCK" & VLLM=$!
  until curl -sf --unix-socket "$SOCK" http://localhost/v1/models >/dev/null; do sleep 10; done
  RB_RUNTIME=frozen scripts/run_experiment.sh "$M" "$SOCK" \
      "$OUT/validated_tasks.txt" "$OUT" "$IMAGES" "$CACHE" "$RUNS"
  kill $VLLM; wait                                        # stops vLLM, next model
done

# Results
python3 scripts/summarize.py "$OUT" "$RUNS/$RB_EXPERIMENT"   # STATS.md, metrics.json there
```

Every step skips work already done, so you can stop and restart at any time. For stages
2 + 3 that means: run again with the same `RB_EXPERIMENT`. Without `RB_EXPERIMENT`, each run
gets a new unique experiment folder, so two people (or two of your jobs) never mix results.
An experiment remembers its settings (`settings.json`: runtime, history, step and time limits,
temperature); resuming it with different ones stops with a message.

- **No network on compute nodes:** pull first on a network node
  (`scripts/pull_task_images.sh "$OUT" "$IMAGES" "$CACHE"`), then run the rest on compute nodes.
- **In parallel:** separate experiments just use different `RB_EXPERIMENT` names. To split one
  experiment, give each job its own part of the task list (`split -n l/8 ...`) and the same
  `RB_EXPERIMENT`; the gold-check lines can also run in parallel
  (see [Reference](docs/REFERENCE.md#parallel-runs)).
- **Little disk:** `RB_DELETE_IMAGE=1 ./command_run_gold.sh` keeps one image at a time, but
  Stages 2/3 then pull each image again.

## Where the results are

| What | Where |
|---|---|
| task folders | `out/exports/<repo>/<instance_id>/` (issue, hidden patches, metadata, bundle) |
| overview of the tasks | `out/SUMMARY.md`, `out/manifest.json` |
| gold check per task | `out/eval_logs/<id>_result.json`, details in `<task>/validation/` |
| gold check summary | `out/eval_logs/scoring_results.json`, `out/validated_tasks.txt` |
| one agent run | `runs/<experiment>/<model>/<id>/`: `candidate.patch`, `trajectory.jsonl`, `selftest.json`, `result.json` |
| experiment settings | `runs/<experiment>/<model>/settings.json` |
| final numbers | `runs/<experiment>/STATS.md`, `runs/<experiment>/metrics.json` (Pass@1 per model, per repository) |
| cluster job logs | `logs/` (Slurm output, `vllm-<model>-<id>.log`, `agents-<model>-<id>-*.log`) |

## Troubleshooting

| Symptom | Look at | Usual cause |
|---|---|---|
| anything at the start | `scripts/check_setup.sh` | it names the missing tool, permission or site |
| `Permission denied` running a script | `ls -l scripts/` | executable bits lost: run the `chmod +x` line the check prints |
| `PULL FAILED` | `$IMAGES/tasks/<id>.sif.pull.log` | no access to `ghcr.io` / Docker Hub from this node |
| pull fails with `unpack entry ... invalid argument` | the same log | `APPTAINER_TMPDIR` is on a network file system that rejects names like `:.1.gz`; use local disk: `export APPTAINER_TMPDIR=/tmp/$USER/apptainer-tmp` |
| gold check `oracle_no_test_results` | `<task>/validation/oracle-*-1.log` | build failed offline: missing dependency, wrong JDK |
| `WARNING ... no Maven/Gradle cache` | pull output | `/root` unreadable in the image and `--fakeroot` not allowed |
| run status `leak_selftest_failed` | `runs/<experiment>/<model>/<id>/selftest.json` | the sandbox could reach the network or the image's repo copy |
| agent `model_server_error` | `runs/<experiment>/<model>/<id>/trajectory.jsonl` | vLLM not up, wrong socket or model name |
| out of memory with a 2-GPU model | `scripts/check_multi_gpu.sh <model> 2` | job got 1 GPU (`--gres=gpu:h200:2`?), or the GPU count in `configs/models.json` |
| `... was made with other settings` | the message | resuming an experiment with changed settings: use a new `RB_EXPERIMENT` |
| agent never calls tools | trajectory | tool-parser flag for that model in `configs/models.json` |

What has and has not been run yet is listed in [docs/PIPELINE.md](docs/PIPELINE.md#status).
