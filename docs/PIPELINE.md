# How it works

[← README](../README.md)

## Stage 1 — Setup (network ON)

### Tasks: `scripts/prepare_all.sh`

1. **Convert** `data/java.csv` into one folder per task (`convert_tddbench.py`).
2. **Check patches** at each base commit, and re-create those whose whitespace or CRLF
   endings were lost in the CSV, about 1 in 7 (`normalize_patches.py`). The CSV version is
   kept as `*.orig.patch`; patches that still fail are flagged and skipped.
3. **Infer a JDK** for the 93 Multi-SWE-bench rows that don't state one, from the build
   files at the base commit (`detect_jdk.py`). Example: Mockito → 11, from
   `gradle/java-library.gradle`; the Gradle wrapper version caps the newest usable JDK.
4. **Bundle** each task's repository with history up to the base commit only, and no remote
   (`make_bundles.sh`).

Per task, `out/exports/<repo>/<instance_id>/`:

| File | Model sees it? | Used by |
|---|---|---|
| `problem_statement.md` | yes | agent (issue text only; hints are never shown) |
| `repo.bundle` | yes, as the workspace | all stages |
| `test.patch` | no | gold check, evaluation |
| `gold.patch` | no | gold check only |
| `metadata.json` | no | harness: base commit, JDK, build tool, test classes, offline test command, images, flags |
| `validation/verdict.json` | no | frozen profile and the fail-to-pass / pass-to-pass lists |

Test selection comes from the files in `test.patch` (by name, or by `@Test`-style markers
for names like `Issue2096`). The offline test command is, for example,
`mvn -o -B clean verify -pl gson -am -Dtest=JsonReaderTest ...`, or for Gradle
`gradle --offline --continue :module:test --tests <FQCN>` (with the wrapper if present).

### Runtimes: `RB_RUNTIME`

| | `frozen` (used in the README) | `built` |
|---|---|---|
| Image | one per task: the SWE-PolyBench (GHCR) or Multi-SWE-bench (Docker Hub) image, pulled with `apptainer pull docker://...` | ours, `environments/java.def`, one per JDK (8, 11, 17, 21) |
| Dependencies | the image's own Maven/Gradle cache, extracted once | one shared cache, `warm_dependencies.sh` |
| JDK | what the image was built with | stated or inferred; ORACLE-first search over JDKs |
| Pick it when | you want environments already verified by SWE-PolyBench | you want full control, as for the C/C++ repos |

`built` setup: `scripts/build_images.sh "$IMAGES" out`, then
`scripts/stage1_all.sh out "$IMAGES" "$CACHE"`.

### Gold check (validation): `run_gold.sh` / `validate_task.sh`

Offline, in the task's image:

- **ORACLE** = base + gold.patch + test.patch → all selected tests must pass;
- **BASE** = base + test.patch → used to find the tests the fix makes pass;
- **fail-to-pass** = pass in ORACLE, not in BASE; **pass-to-pass** = pass in both;
- repeated 3 times; the lists must be identical every time.

Verdicts: `valid_fail_to_pass` (goes to the agent), `bug_not_reproduced`, `oracle_failed`,
`oracle_no_test_results` (build or environment problem), `unstable`.
With `RB_RUNTIME=built`, if ORACLE fails on the task's JDK the next JDK is tried
(ORACLE-first, as in the C/C++ pipeline).

## Stage 2 — Patch creation (network OFF for the model)

Four open-weight models from Hugging Face (`configs/models.json`):

| Name | Hugging Face repo |
|---|---|
| qwen3-coder-next | `Qwen/Qwen3-Coder-Next` |
| gpt-oss-120b | `openai/gpt-oss-120b` |
| devstral-small | `mistralai/Devstral-Small-2507` |
| glm-4.7-flash | `zai-org/GLM-4.7-Flash` |

One vLLM server per GPU node (`serve_model.sh`), weights mounted read-only, Hugging Face
offline mode on. For each task, `run_agent.sh`:

1. builds a fresh workspace from `repo.bundle`: no remote, a single commit
   (`RB_HISTORY=base` keeps the history up to base instead);
2. starts an Apptainer instance with `--net --network none --containall` on the profile
   frozen by the gold check; the dependency cache is read-only; Maven and Gradle are forced
   offline; for frozen images an empty folder is mounted over the image's own repo copy, so
   its git history cannot be read;
3. runs the **leak self-test** in that instance. TCP to Maven Central and GitHub, DNS, curl,
   an online Maven download and `git fetch` must all fail; there must be no git remote and a
   single commit; the image's repo copy must be hidden. If anything fails, the agent is not
   started;
4. runs `agent/agent.py`: the harness talks to vLLM from outside; every tool call (`bash`,
   `str_replace`, `write_file`, `finish`) runs inside the instance;
5. saves `candidate.patch` (the full workspace diff) and the run records.

## Stage 3 — Evaluation (network OFF)

`evaluate_candidate.sh`: fresh base checkout → apply `candidate.patch` → restore the files
`test.patch` touches (SWE-bench convention) → apply `test.patch` → run the task's tests →
**resolved** if every fail-to-pass and every pass-to-pass test passes.

| Outcome | Counts in Pass@1? |
|---|---|
| `resolved`, `unresolved`, `patch_apply_failed`, `empty_patch` | yes |
| `missing_validation`, `missing_candidate`, `eval_no_test_results` | no, kept missing (never counted as failures) |

`summarize.py` reports Pass@1 per model over all validated tasks, over the tasks every model
was scored on, and per repository.

## Status

Checked where this repo was written (no real Apptainer, registries, Maven Central or GPUs
available there):

- conversion of all 250 rows; bundles and patch checks for all 34 gson tasks;
- JDK inference on jackson-core (8) and Mockito (11);
- the whole pipeline on a synthetic task with `tests/e2e_fake.sh`: fake `apptainer` with real
  bind mounts and a real empty network namespace, fake `mvn`, scripted model server; both
  runtimes; correct, wrong and empty patches scored as expected; the leak self-test fails
  when a remote, extra history or the image's repo copy is visible.

Not yet run for real; expect adjustments on the first task: image pulls and cache extraction
(`/root` permissions), the `java.def` download URLs, vLLM tool-parser flags for your vLLM
version, Gradle task paths in multi-project builds (`gradle_task_paths_need_review`), and
GLM-4.7-Flash's licence and size on its model card.

All dated tasks are from 2016–2024 (`likely_in_training_data`): use them to bring up the Java
runtime and harness, not for contamination-safe Pass@1.
