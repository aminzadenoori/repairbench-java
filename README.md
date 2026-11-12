# TDD-Bench-Java → RepairBench (Apptainer only)

Turns the 250 TDD-Bench-Java instances (`data/java.csv`) into repair tasks for the Java
extension of the C/C++ pipeline, and runs four open LLMs from Hugging Face on them in the
three stages of the plan. **Everything runs in Apptainer; no Docker daemon is needed.**

TDD-Bench originally asks a model to write *tests*. Here the same PRs are used the
RepairBench way: the model gets the issue and the code at the base commit and writes the
*fix*; the PR's tests stay hidden and score it.

```
Stage 1  Setup (network ON)      tasks, bundles, images, dependency caches, ORACLE/BASE validation
Stage 2  Patch creation (OFF)    open LLM + agent loop; every command in an offline Apptainer instance
Stage 3  Evaluation (OFF)        candidate.patch + hidden test.patch on a fresh base -> resolved?
```

## Two runtimes, same scripts (`RB_RUNTIME`)

| | `built` (default) | `frozen` |
|---|---|---|
| Image | ours: `environments/java.def`, one per JDK (8, 11, 17, 21) | one per task: SWE-PolyBench / Multi-SWE-bench images, pulled with `apptainer pull docker://...` |
| Dependencies | one shared cache made by `warm_dependencies.sh` | each image's own Maven/Gradle cache, extracted once |
| JDK choice | stated, else inferred; ORACLE-first search over JDKs | whatever the image was built with |
| Use when | you want full control of the runtime (as for C/C++) | you want the environments IBM/Amazon already verified |

Both run the same validation, agent, leak self-test and evaluation code.

## Layout

```
data/java.csv                  TDD-Bench-Java (IBM, Apache-2.0, see data/LICENSE-TDD-Bench)
configs/models.json            the four Hugging Face models and their vLLM flags
environments/java.def          JDK image (build arg JDK=8|11|17|21; Temurin, Maven 3.9.9, Gradle 8.10.2)
environments/vllm.def          vLLM model server image
agent/agent.py                 agent loop for an OpenAI-compatible server (bash, str_replace, write_file, finish)
scripts/prepare_all.sh         Stage 1a: convert + check patches + infer JDKs + bundles
scripts/build_images.sh        Stage 1b (built): build JDK and vLLM images, record SHA256
scripts/pull_task_images.sh    Stage 1b (frozen): pull per-task images, extract their caches
scripts/stage1_all.sh          Stage 1c: warm-up (built) + ORACLE/BASE validation for many tasks
scripts/run_agent.sh           Stage 2: one model on one task, offline, with leak self-test
scripts/evaluate_candidate.sh  Stage 3: score one candidate.patch
scripts/run_experiment.sh      Stages 2+3 for a model over a task list (resumable)
scripts/summarize.py           metrics.json + STATS.md (Pass@1 per model, per repo)
scripts/download_models.sh     fetch the four models to shared storage
scripts/serve_model.sh         one offline vLLM server per GPU node
tests/e2e_fake.sh              runs the whole pipeline on a synthetic task with fakes (see Tests)
```

Helpers: `convert_tddbench.py`, `normalize_patches.py`, `detect_jdk.py`, `make_bundles.sh`,
`warm_dependencies.sh`, `validate_task.sh`, `leak_selftest.sh`, `parse_junit.py`, `lib.sh`.

## Stage 1 — Setup (network node)

```bash
# a) tasks: CSV -> task folders; patches checked at base; JDK inferred; one bundle per task
scripts/prepare_all.sh out                       # all 13 repos, 250 tasks
scripts/prepare_all.sh out google/gson           # or some repos only

# b) images, EITHER built ...
scripts/build_images.sh "$AI4I_ROOT/singularity/images" out
#    ... OR frozen (per-task images from the SWE-PolyBench / Multi-SWE-bench registries)
RB_RUNTIME=frozen scripts/pull_task_images.sh out "$AI4I_ROOT/singularity/images" "$AI4I_ROOT/cache/java"

# c) dependencies + validation (ORACLE first, then BASE, 3 repetitions each)
scripts/stage1_all.sh out "$AI4I_ROOT/singularity/images" "$AI4I_ROOT/cache/java"                    # built
RB_RUNTIME=frozen scripts/stage1_all.sh out "$AI4I_ROOT/singularity/images" "$AI4I_ROOT/cache/java"  # frozen
```

If compute nodes have no network: `ONLY_PREPARE=1` on a network node, then
`ONLY_VALIDATE=1` on compute nodes. Validation is always offline.

Per task (`out/exports/<repo>/<instance_id>/`):

| File | Model sees it? | Used by |
|---|---|---|
| `problem_statement.md` | yes | agent |
| `repo.bundle` | yes, as the workspace (no remote; one commit by default) | all stages |
| `test.patch` | no | validation, evaluation |
| `gold.patch` | no | ORACLE validation only |
| `metadata.json` | no | harness: base commit, JDK, build tool, test classes, offline test command, images, flags |
| `validation/verdict.json` | no | frozen profile + fail-to-pass / pass-to-pass lists for evaluation |

Verdicts: `valid_fail_to_pass` (goes to the agent), `bug_not_reproduced`, `oracle_failed`,
`oracle_no_test_results` (build/environment problem), `unstable`. The list of valid tasks
is written to `out/validated_tasks.txt`.

### What the conversion does

- **Problem statement:** issue text only, duplicated copies removed; `hints_text` is kept in
  `metadata.json` and never shown to the model.
- **Tests:** test classes come from the files in `test.patch` (by name, or by `@Test`-style
  markers for names like `Issue2096`); helper classes, `.sql` and `.proto` files are not run.
- **Offline test command,** e.g. `mvn -o -B clean verify -pl gson -am -Dtest=JsonReaderTest ...`,
  or `gradle --offline --continue :module:test --tests <FQCN>` (the wrapper is used if present).
- **JDK:** from the SWE-PolyBench Dockerfile (8 or 11); for the 93 Multi-SWE-bench rows it is
  inferred from the build files at the base commit (e.g. Mockito → 11 from
  `gradle/java-library.gradle`, Gradle wrapper version caps the newest usable JDK) and
  flagged `jdk_inferred`. Validation still tries other JDKs if ORACLE fails.
- **Patches:** about 1 in 7 lost whitespace or CRLF endings in the CSV; they are re-created
  from the real repository (`*.orig.patch` keeps the CSV version). Still failing →
  `patch_does_not_apply`, skipped.
- **Upstream F2P/P2P** lists are kept for comparison only; ours come from validation.
- **Review flags:** `likely_in_training_data` (all dated tasks are 2016–2024), `date_unknown`,
  `jdk_inferred`, `no_test_class_detected`, `gradle_task_paths_need_review`,
  `test_patch_touches_main_sources`, `gold_over_1000_lines`, `gold_over_20_files`,
  `problem_statement_short`, `touches_android_variant`, `patch_does_not_apply`.

## Stage 2 — Patch creation (network OFF for the model)

Models (`configs/models.json`), four vendors, all open weights on Hugging Face:

| Name | Hugging Face repo |
|---|---|
| qwen3-coder-next | `Qwen/Qwen3-Coder-Next` |
| gpt-oss-120b | `openai/gpt-oss-120b` |
| devstral-small | `mistralai/Devstral-Small-2507` |
| glm-4.7-flash | `zai-org/GLM-4.7-Flash` |

```bash
MODELS_ROOT=/shared/models scripts/download_models.sh                       # network node, once
MODELS_ROOT=/shared/models VLLM_SIF=$AI4I_ROOT/singularity/images/vllm.sif \
    scripts/serve_model.sh qwen3-coder-next 8000 1 &                           # GPU node
scripts/run_experiment.sh qwen3-coder-next http://127.0.0.1:8000/v1 out/validated_tasks.txt \
    out "$AI4I_ROOT/singularity/images" "$AI4I_ROOT/cache/java" runs           # add RB_RUNTIME=frozen if used
```

Repeat per model (one vLLM server at a time per node), with the same budget
(`RB_MAX_STEPS`, `RB_MAX_SECONDS`) and history profile (`RB_HISTORY=none` default, `base`
for the pre-base-history run).

For each task, `run_agent.sh`:
1. builds a fresh workspace from `repo.bundle`: no remote, a single commit (or the history up
   to base only with `RB_HISTORY=base`);
2. starts an Apptainer instance with `--net --network none --containall` on the profile
   frozen by validation; the dependency cache is mounted read-only, Maven/Gradle are forced
   offline (`MAVEN_ARGS=-o`, a Gradle init script), and for frozen images an empty directory
   is mounted over the image's own repo copy so its git history can't be read;
3. runs the **leak self-test** inside the instance: TCP to Maven Central and GitHub, DNS,
   curl, an online Maven download and `git fetch` must all fail; no git remote; one commit;
   image repo copy hidden. If any check fails, the agent is not started;
4. runs `agent/agent.py`: the harness talks to vLLM from outside; every tool call (bash,
   file edits) runs inside the instance;
5. saves `candidate.patch` (the full workspace diff), `trajectory.jsonl`, `agent.json`,
   `selftest.json`, `run.json` (model, runtime, image SHA256, budget, stop reason).

## Stage 3 — Evaluation (network OFF)

`evaluate_candidate.sh` (called by `run_experiment.sh`): fresh base checkout → apply
`candidate.patch` → restore the files `test.patch` touches (SWE-bench convention) → apply
`test.patch` → run the task's tests on the frozen profile → **resolved** iff every
fail-to-pass and every pass-to-pass test passes.

Outcomes counted in Pass@1: `resolved`, `unresolved`, `patch_apply_failed`, `empty_patch`.
Kept missing (never counted as failures): `missing_validation`, `missing_candidate`,
`eval_no_test_results`.

```bash
python3 scripts/summarize.py out runs     # runs/metrics.json + runs/STATS.md
```

Pass@1 per model over all validated tasks, over the tasks every model was scored on, and
per repository (the Java slice).

## Relation to SWE-PolyBench / TDD-Bench's harness

TDD-Bench's `command_run_gold.sh` runs IBM's patched SWE-PolyBench harness
(`tdd_java.diff` on commit `1963184`). That harness needs a Docker daemon (Python `docker`
SDK), and in IBM's version `model_patch` is a *test* patch. Here:

- the same per-instance images are used through Apptainer (`RB_RUNTIME=frozen`): GHCR
  `ghcr.io/timesler/swe-polybench.eval.x86_64.<id>` (pinned `:v1.1`, falling back to the
  `:latest` tag IBM uses) and Docker Hub `mswebench/...:pr-<n>` for the Multi-SWE-bench rows;
- their gold check (old code vs. gold + tests) corresponds to our ORACLE/BASE validation
  (`stage1_all.sh`), run offline and repeated 3 times;
- their scoring of a model's *test* patch is replaced by scoring a model's *fix* against
  the hidden tests (Stage 3).

## Tests

```bash
tests/e2e_fake.sh
```

Runs the full pipeline (validation ×3 → agent with leak self-test → evaluation of a
correct, a wrong and an empty patch → metrics) for both runtimes on a synthetic Java task,
using a fake `apptainer` (real bind mounts and a real empty network namespace via
`unshare`), a fake `mvn` and a scripted model server. Needs root or unprivileged user
namespaces. This passes in the environment where the repo was written.

## Not yet run against the real stack

No real Apptainer, Maven Central, registries or GPUs were reachable where this was written.
Checked for real: the conversion of all 250 rows, bundles and patch checks for all 34 gson
tasks, JDK inference on jackson-core and Mockito, and the whole pipeline logic through
`tests/e2e_fake.sh`. On the first real task, expect to adjust: image build details
(Adoptium/Maven URLs), vLLM tool-parser flags for your vLLM version, cache extraction from
frozen images (`/root` permissions; `--fakeroot` is tried first), and Gradle task paths for
multi-project builds (`gradle_task_paths_need_review`). Check GLM-4.7-Flash's licence and
size on its model card.
