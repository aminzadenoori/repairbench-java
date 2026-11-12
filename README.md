# TDD-Bench-Java → RepairBench tasks

Turns the 250 TDD-Bench-Java instances (`data/java.csv`) into RepairBench-style repair
tasks for the Java extension of the C/C++ pipeline, and sets up four open LLMs from
Hugging Face to solve them offline.

TDD-Bench originally asks a model to write *tests*. Here the same PRs are used the
RepairBench way: the model gets the issue and the code at the base commit and must write
the *fix*; the PR's tests are hidden and used for scoring.

## Layout

```
data/java.csv                 TDD-Bench-Java (IBM, Apache-2.0, see data/LICENSE-TDD-Bench)
configs/models.json           the four Hugging Face models and their vLLM flags
scripts/convert_tddbench.py   CSV -> task folders, manifest, per-repo configs, SUMMARY.md
scripts/normalize_patches.py  check every patch at its base commit; repair whitespace-damaged ones
scripts/make_bundles.sh       one repo.bundle per task (history up to base only, no remote)
scripts/warm_dependencies.sh  download a task's Maven/Gradle dependencies (network ON)
scripts/smoke_validate.sh     ORACLE/BASE check of one task, offline, N repetitions
scripts/parse_junit.py        JUnit XML -> {classname::name: status}
scripts/download_models.sh    fetch the four models to shared storage
scripts/serve_model.sh        one offline vLLM server per GPU node
scripts/prepare_all.sh        convert + normalize + bundle in one go
```

## 1. Prepare all tasks (network node)

```bash
scripts/prepare_all.sh out                    # all 13 repos, 250 tasks
scripts/prepare_all.sh out google/gson        # or only some repos
```

Output per task, in `out/exports/<repo>/<instance_id>/`:

| File | Given to the model? | Used by |
|---|---|---|
| `problem_statement.md` | yes | agent |
| `repo.bundle` | yes (as the workspace) | agent, validator, evaluator |
| `test.patch` | no | BASE/ORACLE, evaluation |
| `gold.patch` | no | ORACLE only |
| `metadata.json` | no | harness: base commit, JDK, build tool, test classes, offline test command, review flags |

Also written: `out/manifest.json` (one line of facts and flags per task),
`out/configs/<repo>-tddbench-jdk<N>.json` (one config per repo and JDK, following the plan
template) and `out/SUMMARY.md`.

Disk: bundles keep each task's full history up to its base commit. For trino, dubbo and
rocketmq this is hundreds of MB per task; put `out/` and `mirrors-full/` on scratch storage.

### What the conversion does

- **Problem statement:** issue text only, with the duplicated copy (rows that link the same
  issue twice) removed. `hints_text` stays in `metadata.json` and is never shown to the model.
- **Test selection:** test classes are taken from the files in `test.patch` (by name, or by
  `@Test`-style markers for names like `Issue2096`). Helper classes, `.sql` and `.proto`
  files are not run as tests, which upstream's `-Dtest` list sometimes did.
- **Offline test command:** e.g. `mvn -o -B clean verify -pl gson -am -Dtest=JsonReaderTest ...`;
  for Gradle `gradle --offline --continue :module:test --tests <FQCN>`.
- **JDK:** read from the SWE-PolyBench Dockerfile (8 or 11). The 93 Multi-SWE-bench rows
  don't say; they are flagged `jdk_unknown` (their Docker images `mswebench/...` do).
- **Upstream F2P/P2P lists** are kept for comparison only. Recompute them with validation:
  for some tasks (e.g. gson-2337) upstream lists the whole test class as fail-to-pass.
- **Patches:** about 1 in 7 gson patches lost whitespace in the CSV and do not apply
  exactly. `normalize_patches.py` re-creates them from the real repo and keeps the CSV
  version as `*.orig.patch`; anything that still fails is flagged `patch_does_not_apply`.

### Review flags (in `manifest.json` and `metadata.json`)

`likely_in_training_data` (dated before 2025), `date_unknown`, `jdk_unknown`,
`no_upstream_test_lists`, `no_test_class_detected`, `gradle_task_paths_need_review`,
`test_patch_touches_main_sources`, `gold_over_1000_lines`, `gold_over_20_files`,
`problem_statement_short`, `touches_android_variant`, `patch_does_not_apply`.

All dated tasks are from 2016–2024, so treat this set as the bring-up set for the Java
runtime and harness, not as contamination-safe scoring.

## 2. Freeze dependencies (network node, inside the JDK image)

```bash
for t in out/exports/gson/*/; do
  apptainer exec --bind "$PWD" "$AI4I_ROOT/singularity/images/java-ubuntu22.04-jdk11.sif" \
      scripts/warm_dependencies.sh "$t" "$AI4I_ROOT/cache/java"
done
```

Use the task's JDK (`metadata.json` → `environment.jdk`). The build runs once with gold and
test patches applied, so test-only dependencies and the Surefire/JUnit providers are cached.

## 3. Validate (offline)

```bash
scripts/smoke_validate.sh out/exports/gson/google__gson-2337 \
    "$AI4I_ROOT/singularity/images/java-ubuntu22.04-jdk11.sif" "$AI4I_ROOT/cache/java" 3
cat out/exports/gson/google__gson-2337/smoke/verdict.json
```

Verdicts: `valid_fail_to_pass`, `bug_not_reproduced`, `oracle_failed`,
`oracle_no_test_results` (build or environment problem), `unstable`. This is a bring-up
check; the canonical RepairBench validator stays the reference. Point it at
`out/configs/*.json` (`build_profile: commands`, `allow_network: false`).

## 4. Models (four open LLMs from Hugging Face)

| Name | Hugging Face repo | Vendor |
|---|---|---|
| qwen3-coder-next | `Qwen/Qwen3-Coder-Next` | Alibaba Qwen |
| gpt-oss-120b | `openai/gpt-oss-120b` | OpenAI (open weights) |
| devstral-small | `mistralai/Devstral-Small-2507` | Mistral AI |
| glm-4.7-flash | `zai-org/GLM-4.7-Flash` | Zhipu AI |

```bash
MODELS_ROOT=/shared/models scripts/download_models.sh            # network node, once
MODELS_ROOT=/shared/models VLLM_SIF=vllm.sif scripts/serve_model.sh qwen3-coder-next 8000 1
```

One server per GPU node; many agent containers send requests to it, so each model is in
GPU memory once per node. The weights folder is mounted read-only and the server runs
with `HF_HUB_OFFLINE=1`.

Check before the first run: the vLLM tool-call parser names in `configs/models.json`
change between vLLM versions, and GLM-4.7-Flash's licence and size should be confirmed on
its model card.

## 5. Agent runs (offline)

Every tool command the agent issues runs in an Apptainer instance with no network:

```bash
apptainer instance start --net --network none --bind "$WS:/workspace" \
    --bind "$AI4I_ROOT/cache/java:/cache:ro" java-ubuntu22.04-jdk11.sif task_$ID
apptainer exec --pwd /workspace instance://task_$ID bash -lc "$CMD"
```

The harness talks to the vLLM server from outside the instance. Run the same task set
with each of the four models, the same harness profile and budget, then score every
`candidate.patch` with the canonical evaluator. Keep Java as its own slice in
`metrics.json`.

## Not tested here

The scripts were written and checked without access to Maven Central, Docker Hub or
GPUs. The conversion was run on all 250 rows, and gson bundles and patch checks were run
against GitHub. The dependency warm-up, the smoke validation and the model serving have
not been executed yet; expect to adjust flags on the first task.
