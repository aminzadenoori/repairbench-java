# Relation to TDD-Bench and SWE-PolyBench

[← README](../README.md)

TDD-Bench-Java (IBM) collects 250 Java instances from SWE-PolyBench (157) and
Multi-SWE-bench (93). Its `command_run_gold.sh` runs IBM's patched SWE-PolyBench harness
(`tdd_java.diff` on commit `1963184`) once per instance with `--evaluate-gold`.

Two things differ here:

1. **Apptainer instead of Docker.** The SWE-PolyBench harness drives containers through the
   Python `docker` SDK, so it needs a Docker daemon. This repo uses the same per-instance
   images through `apptainer pull docker://...` and runs them with Apptainer.
2. **Fixes instead of tests.** In IBM's version, the prediction's `model_patch` is applied as
   a *test* patch (TDD: the model writes tests). Here the model writes the *fix*, and the PR's
   tests score it.

## Gold check, side by side

| TDD-Bench (`run_evaluation.py`) | This repo (`run_gold.sh`) |
|---|---|
| `--instance_id_to_run <id>` | last argument |
| pull from GHCR (`:latest`) or `mswebench` with Docker | `apptainer pull`; GHCR `:v1.1` first, then `:latest`; `mswebench/...:pr-<n>` |
| repo in the image at `/testbed` or `<WorkingDir>/<repo>` | same paths, hidden from the agent |
| run tests before and after the gold patch | ORACLE / BASE offline, 3 repetitions |
| `eval_logs/<id>_result.json` with `resolved` | same file and field, plus verdict and fail-to-pass tests |
| `--skip-existing` | existing result is skipped |
| `--delete-image` | `RB_DELETE_IMAGE=1` (off by default: Stages 2–3 reuse the images) |
| `--score-only` → `scoring_results.json` | `scripts/score_gold.py "$OUT"` |

`command_run_gold.sh` here has the same 250 instances in the same order as IBM's.

## Data

`data/java.csv` is TDD-Bench-Java's `java.csv` (Apache-2.0, `data/LICENSE-TDD-Bench`).
Upstream fail-to-pass / pass-to-pass lists are kept in `metadata.json` for comparison only;
some are not usable as they are (for `google__gson-2337` the whole test class is listed as
fail-to-pass). The lists used for scoring come from our own gold check.
