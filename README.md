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
| disk | scratch space: images are 1–5 GB per task, model weights hundreds of GB in total |

```bash
apptainer --version && git --version && python3 --version
```

## Install

Nothing to compile or `pip install` for the pipeline itself.

```bash
unzip tddbench-java-repairbench.zip        # or: git clone <your copy of this repo>
cd tddbench-java-repairbench

# where large files go (use scratch, not home)
export IMAGES=/scratch/$USER/rb/images     # .sif images
export CACHE=/scratch/$USER/rb/cache       # Maven/Gradle caches
export APPTAINER_CACHEDIR=/scratch/$USER/rb/apptainer-cache
export APPTAINER_TMPDIR=/scratch/$USER/rb/tmp
mkdir -p "$IMAGES" "$CACHE" "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"

# optional: test the whole pipeline with stand-ins (needs root or user namespaces)
tests/e2e_fake.sh                          # ends with: ALL E2E CHECKS PASSED
```

## Quick start

One repository, one task, end to end.

```bash
# 1. prepare the gson tasks (network node)
scripts/prepare_all.sh out google/gson

# 2. gold check of one task: old code fails, real fix passes (pulls its image)
RB_DELETE_IMAGE=0 scripts/run_gold.sh out "$IMAGES" "$CACHE" google__gson-2337
cat out/eval_logs/google__gson-2337_result.json          # want "resolved": true

# 3. start one model (GPU node), once the weights and vLLM image exist (see below)
VLLM_SIF="$IMAGES/vllm.sif" MODELS_ROOT=/scratch/$USER/rb/models \
    scripts/serve_model.sh qwen3-coder-next 8000 1 &

# 4. agent + evaluation on that task
echo google__gson-2337 > one.txt
RB_RUNTIME=frozen scripts/run_experiment.sh qwen3-coder-next http://127.0.0.1:8000/v1 \
    one.txt out "$IMAGES" "$CACHE" runs
cat runs/qwen3-coder-next/google__gson-2337/result.json  # "outcome": "resolved" or not
```

Model weights and the vLLM image, once:

```bash
pip install -U "huggingface_hub[cli]"
export MODELS_ROOT=/scratch/$USER/rb/models
scripts/download_models.sh                                # the four models
apptainer build --fakeroot --build-arg VLLM_VERSION=v0.11.0 "$IMAGES/vllm.sif" environments/vllm.def
```

## Run everything

```bash
# Stage 1: all 250 tasks
scripts/prepare_all.sh out
RB_DELETE_IMAGE=0 OUT=out ./command_run_gold.sh           # gold check, one line per instance
python3 scripts/score_gold.py out                         # -> out/validated_tasks.txt

# Stages 2 + 3: each of the four models
for M in qwen3-coder-next gpt-oss-120b devstral-small glm-4.7-flash; do
  scripts/serve_model.sh "$M" 8000 1 &
  until curl -sf http://127.0.0.1:8000/v1/models >/dev/null; do sleep 10; done
  RB_RUNTIME=frozen scripts/run_experiment.sh "$M" http://127.0.0.1:8000/v1 \
      out/validated_tasks.txt out "$IMAGES" "$CACHE" runs
  kill %1; wait
done

# Results
python3 scripts/summarize.py out runs                     # runs/STATS.md, runs/metrics.json
```

Every step skips work already done, so you can stop and restart at any time.

- **No network on compute nodes:** pull first on a network node
  (`scripts/pull_task_images.sh out "$IMAGES" "$CACHE"`), then run the rest on compute nodes.
- **In parallel:** split the task list (`split -n l/8 out/validated_tasks.txt part_`) and give
  each job its own part with the same `runs/` folder; the gold-check lines can also run in
  parallel (see [Reference](docs/REFERENCE.md#parallel-runs)).
- **Little disk:** `RB_DELETE_IMAGE=1` keeps one image at a time in the gold check, but Stages
  2/3 then pull each image again.

## Where the results are

| What | Where |
|---|---|
| task folders | `out/exports/<repo>/<instance_id>/` (issue, hidden patches, metadata, bundle) |
| overview of the tasks | `out/SUMMARY.md`, `out/manifest.json` |
| gold check per task | `out/eval_logs/<id>_result.json`, details in `<task>/validation/` |
| gold check summary | `out/eval_logs/scoring_results.json`, `out/validated_tasks.txt` |
| one agent run | `runs/<model>/<id>/`: `candidate.patch`, `trajectory.jsonl`, `selftest.json`, `result.json` |
| final numbers | `runs/STATS.md`, `runs/metrics.json` (Pass@1 per model, per repository) |

## Troubleshooting

| Symptom | Look at | Usual cause |
|---|---|---|
| `PULL FAILED` | `$IMAGES/tasks/<id>.sif.pull.log` | no access to `ghcr.io` / Docker Hub from this node |
| gold check `oracle_no_test_results` | `<task>/validation/oracle-*-1.log` | build failed offline: missing dependency, wrong JDK |
| `WARNING ... no Maven/Gradle cache` | pull output | `/root` unreadable in the image and `--fakeroot` not allowed |
| run status `leak_selftest_failed` | `runs/<model>/<id>/selftest.json` | the sandbox could reach the network or the image's repo copy |
| agent `model_server_error` | `runs/<model>/<id>/trajectory.jsonl` | vLLM not up, wrong port or model name |
| agent never calls tools | trajectory | tool-parser flag for that model in `configs/models.json` |

What has and has not been run yet is listed in [docs/PIPELINE.md](docs/PIPELINE.md#status).
