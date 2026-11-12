# Reference

[← README](../README.md)

## Scripts

| Script | Stage | What it does |
|---|---|---|
| `scripts/prepare_all.sh [out] [repo\|id ...]` | 1 | convert + check patches + infer JDKs + bundles |
| `command_run_gold.sh` | 1 | gold check of all 250 instances, one line each (env: `OUT`, `IMAGES`, `CACHE`) |
| `scripts/run_gold.sh out IMAGES CACHE <id>` | 1 | one instance: pull, gold check, `eval_logs/<id>_result.json` |
| `scripts/score_gold.py out` | 1 | gold-check summary + `validated_tasks.txt` |
| `scripts/pull_task_images.sh out IMAGES CACHE [repo\|id ...]` | 1 | frozen runtime: pull images, extract caches |
| `scripts/build_images.sh IMAGES [out]` | 1 | built runtime: JDK 8/11/17/21 + vLLM images, SHA256 into configs |
| `scripts/stage1_all.sh out IMAGES CACHE [repo\|id ...]` | 1 | warm-up (built) / pull (frozen) + validation for many tasks |
| `scripts/validate_task.sh <task> IMAGES CACHE [reps]` | 1 | ORACLE/BASE validation of one task |
| `scripts/warm_dependencies.sh <task> CACHE IMAGES [jdk]` | 1 | built runtime: download one task's dependencies |
| `scripts/download_models.sh [name ...]` | 2 | Hugging Face weights to `MODELS_ROOT` |
| `scripts/serve_model.sh <name> [port] [tp]` | 2 | offline vLLM server for one model |
| `scripts/run_agent.sh <task> <model> <url> IMAGES CACHE runs` | 2 | one model on one task, with leak self-test |
| `scripts/leak_selftest.sh out.json history hidden -- <exec>` | 2 | the sandbox checks, on their own |
| `scripts/evaluate_candidate.sh <task> <run_dir> IMAGES CACHE` | 3 | score one `candidate.patch` |
| `scripts/run_experiment.sh <model> <url> list out IMAGES CACHE runs` | 2+3 | agent + evaluation over a task list |
| `scripts/summarize.py out runs` | 3 | `metrics.json` + `STATS.md` |
| `tests/e2e_fake.sh` | — | the whole pipeline with stand-ins |

Helpers: `convert_tddbench.py`, `normalize_patches.py`, `detect_jdk.py`, `make_bundles.sh`,
`parse_junit.py`, `lib.sh`.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `RB_RUNTIME` | `built` (`frozen` in `run_gold.sh`) | `frozen` = per-task registry images, `built` = our JDK images |
| `RB_REPETITIONS` | 3 | ORACLE/BASE repetitions in the gold check |
| `RB_DELETE_IMAGE` | 1 in `command_run_gold.sh`, else unset | delete each image after its gold check |
| `RB_JDK_ORDER` | `11 17 8 21` | built runtime: JDKs to try after the task's own |
| `RB_HISTORY` | `none` | agent workspace: `none` (one commit) or `base` (history up to base) |
| `RB_MAX_STEPS` / `RB_MAX_SECONDS` | 100 / 3600 | agent budget per task |
| `RB_TEMPERATURE` | 0 | sampling temperature |
| `RB_ALLOW_UNVALIDATED` | unset | run the agent on tasks without a valid gold check |
| `KEEP_WORKSPACE` | unset | keep the agent's workspace for debugging |
| `ONLY_PREPARE` / `ONLY_VALIDATE` | unset | `stage1_all.sh`: split network and compute parts |
| `MODELS_ROOT`, `VLLM_SIF` | — | model weights folder, vLLM image |
| `APPTAINER_CACHEDIR`, `APPTAINER_TMPDIR` | — | put on scratch: pulls are large |

## Review flags

Set per task in `manifest.json` and `metadata.json`:

`likely_in_training_data`, `date_unknown`, `jdk_inferred`, `no_upstream_test_lists`,
`no_test_class_detected`, `gradle_task_paths_need_review`, `test_patch_touches_main_sources`,
`gold_over_1000_lines`, `gold_over_20_files`, `problem_statement_short`,
`touches_android_variant`, `patch_does_not_apply` (skipped).

## Parallel runs

Every instance and every run uses its own folders, so jobs can share `out/`, `runs/` and the
image folder.

```bash
# gold check, 4 at a time
export OUT=out IMAGES=... CACHE=... RB_DELETE_IMAGE=0
grep "^scripts/run_gold" command_run_gold.sh | parallel -j 4

# agent runs, 8 cluster jobs for one model
split -n l/8 out/validated_tasks.txt part_
# job k: scripts/run_experiment.sh <model> <url> part_<k> out $IMAGES $CACHE runs
```

## Disk

- frozen images: 1–5 GB each (up to several hundred GB for all 250); caches extracted from
  them add more;
- bundles: small for gson and the Jackson repos, hundreds of MB per task for trino, dubbo and
  rocketmq;
- model weights: hundreds of GB for the four models.
