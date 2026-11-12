#!/usr/bin/env python3
"""Convert TDD-Bench-Java (java.csv) into RepairBench-style task folders.

For every instance this writes

    <out>/exports/<repo-slug>/<instance_id>/
        problem_statement.md   issue text only (shown to the model)
        gold.patch             human fix from the PR (hidden, ORACLE only)
        test.patch             tests from the PR (hidden, used for scoring)
        metadata.json          everything the harness needs (hidden)

plus

    <out>/manifest.json        one record per task, with review flags
    <out>/configs/<slug>-<jdk>.json   one RepairBench config per repo and JDK
    <out>/SUMMARY.md           counts per repo, per JDK, per flag

The repository bundle is NOT created here: run scripts/make_bundles.sh on a
machine that can clone the repos. Hints text from the CSV is kept in
metadata.json but never written to problem_statement.md.

Usage:
    python3 convert_tddbench.py --csv java.csv --out out_dir [--ai4i-root '${AI4I_ROOT}']
"""
from __future__ import annotations

import argparse
import ast
import csv
import json
import math
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

csv.field_size_limit(sys.maxsize)

# Repos the Java plan (Phase 1) marked as likely fits.
PHASE1_SHORTLIST = {
    "google/gson",
    "fasterxml/jackson-core",
    "fasterxml/jackson-databind",
    "fasterxml/jackson-dataformat-xml",
    "alibaba/fastjson2",
    "mockito/mockito",
}
# Review limits from METHODOLOGY.md.
MAX_GOLD_LINES = 1000
MAX_GOLD_FILES = 20
MIN_PROBLEM_WORDS = 10

TEST_NAME_RE = re.compile(r"(^Test\w*|\w*(Test|Tests|TestCase|IT))\.java$")
DIFF_FILE_RE = re.compile(r"^diff --git a/(\S+) b/(\S+)", re.M)
JDK_RE = re.compile(r"java-(1\.8\.0|\d+)-amazon-corretto")


# --------------------------------------------------------------------------- helpers

def blank(v) -> bool:
    return v is None or (isinstance(v, float) and math.isnan(v)) or str(v).strip() in ("", "nan")


def parse_list(v) -> list | None:
    """CSV list columns are Python literals; missing means unknown (None)."""
    if blank(v):
        return None
    try:
        out = ast.literal_eval(str(v))
    except (ValueError, SyntaxError):
        return None
    return list(out) if isinstance(out, (list, tuple)) else [out]


def dedupe_issue_text(text: str) -> str:
    """Rows linked to the same issue twice repeat the issue body; keep one copy."""
    t = text.strip()
    n = len(t)
    for i in range(n // 2 - 4, n // 2 + 5):
        if 0 < i < n and t[:i].strip() and t[:i].strip() == t[i:].strip():
            return t[:i].strip()
    return t


def changed_files(patch: str) -> list[str]:
    return [b for _, b in DIFF_FILE_RE.findall(patch or "")]


def changed_lines(patch: str) -> int:
    return sum(
        1
        for line in (patch or "").splitlines()
        if (line.startswith("+") and not line.startswith("+++"))
        or (line.startswith("-") and not line.startswith("---"))
    )


def file_diffs(patch: str) -> dict[str, str]:
    """Split a unified diff into {path: that file's diff text}."""
    out, cur, buf = {}, None, []
    for line in (patch or "").splitlines(keepends=True):
        m = DIFF_FILE_RE.match(line)
        if m:
            if cur:
                out[cur] = "".join(buf)
            cur, buf = m.group(2), []
        buf.append(line)
    if cur:
        out[cur] = "".join(buf)
    return out


TEST_MARKERS = ("@Test", "@ParameterizedTest", "extends TestCase", "extends BaseMapTest", "extends BaseTest")


def test_class_of(path: str, diff_text: str = "") -> dict | None:
    """Map a test source file to module, fully qualified class name, and simple name.

    A file counts as a test class if it sits under a test source root and either has a
    test-like name (FooTest, TestFoo, FooIT, ...) or its diff contains a test marker
    such as @Test (catches names like Issue2096 or JsonCreatorModeForEnum3566).
    """
    name = path.rsplit("/", 1)[-1]
    ext = ".java" if name.endswith(".java") else ".groovy" if name.endswith(".groovy") else None
    if ext is None or "/src/main/" in "/" + path:
        return None
    if not (TEST_NAME_RE.search(name.replace(".groovy", ".java")) or any(k in diff_text for k in TEST_MARKERS)):
        return None
    lang = ext.strip(".")
    for root in (f"/src/test/{lang}/", f"/src/integrationTest/{lang}/", f"/src/it/{lang}/", "/test/"):
        p = "/" + path
        if root in p:
            module, rel = p.split(root, 1)
            fqcn = rel[: -len(ext)].replace("/", ".")
            return {"module": module.strip("/"), "fqcn": fqcn, "class": name[: -len(ext)], "path": path}
    return None


def build_tool_of(cmd: str) -> str:
    if "gradle" in cmd:
        return "gradle"
    if "mvn" in cmd:
        return "maven"
    return "unknown"


def upstream_build_command(cmd: str) -> str:
    """Strip the harness wrapper (report cleanup, JDK switching, XML dumping)."""
    parts = [p.strip() for p in cmd.split(";")]
    keep = []
    for p in parts:
        if p.startswith("find ") or p.startswith("mvn clean") and p == "mvn clean" or p in ("./gradlew clean",):
            continue
        p = re.sub(r"export JAVA_HOME=\S+\s*&&\s*", "", p)
        p = re.sub(r"update-alternatives --set java \S+\s*&&\s*", "", p)
        if p:
            keep.append(p)
    return " ; ".join(keep)


def offline_test_command(tool: str, tests: list[dict]) -> str | None:
    """Our offline, per-task test command (selection comes from test.patch)."""
    if not tests:
        return None
    modules = sorted({t["module"] for t in tests})
    if tool == "maven":
        sel = ",".join(sorted({t["class"] for t in tests}))
        pl = f" -pl {','.join(modules)} -am" if all(modules) else " -am"
        return (
            f"mvn -o -B clean verify{pl} -Dtest={sel} -DfailIfNoTests=false "
            "-Dsurefire.failIfNoSpecifiedTests=false -fae"
        )
    if tool == "gradle":
        by_task = defaultdict(list)
        for t in tests:
            task = ":" + t["module"].replace("/", ":") + ":test" if t["module"] else "test"
            by_task[task].append(t["fqcn"])
        args = " ".join(
            f"{task} " + " ".join(f"--tests {f}" for f in sorted(set(fs))) for task, fs in sorted(by_task.items())
        )
        return f"gradle --offline --continue {args}"
    return None


def report_globs(tool: str) -> list[str]:
    if tool == "gradle":
        return ["**/build/test-results/**/TEST-*.xml"]
    return ["**/target/surefire-reports/TEST-*.xml"]


def slug(repo: str) -> str:
    return repo.split("/", 1)[1]


# --------------------------------------------------------------------------- main

def convert(csv_path: Path, out: Path, ai4i_root: str) -> dict:
    rows = list(csv.DictReader(open(csv_path, newline="", encoding="utf-8")))
    manifest = []
    for r in rows:
        iid = r["instance_id"]
        repo = r["repo"].strip()
        image = r.get("image_name", "") or ""
        source = "Multi-SWE-bench" if image.startswith("mswebench") else "SWE-PolyBench"
        cmd = r.get("test_command", "") or ""
        tool = build_tool_of(cmd)
        dockerfile = "" if blank(r.get("Dockerfile")) else r["Dockerfile"]
        m = JDK_RE.search(dockerfile) or JDK_RE.search(cmd)
        jdk = None if not m else ("8" if m.group(1) == "1.8.0" else m.group(1))

        gold, test = r["patch"], r["test_patch"]
        gold_files, test_files = changed_files(gold), changed_files(test)
        diffs = file_diffs(test)
        tests = [t for t in (test_class_of(f, diffs.get(f, "")) for f in test_files) if t]
        support_files = [f for f in test_files if not test_class_of(f, diffs.get(f, ""))]
        problem = dedupe_issue_text(r["problem_statement"] or "")
        created = None if blank(r.get("created_at")) else r["created_at"]
        pr = None if blank(r.get("pull_number")) else int(float(r["pull_number"]))
        issues = parse_list(r.get("issue_numbers")) or ([] if blank(r.get("issue_numbers")) else [r["issue_numbers"]])
        issues = sorted({str(i) for i in issues}, key=lambda s: (len(s), s))

        flags = []
        if source == "Multi-SWE-bench":
            flags.append("no_upstream_test_lists")
        if jdk is None:
            flags.append("jdk_unknown")
        if not tests:
            flags.append("no_test_class_detected")
        if tool == "gradle":
            flags.append("gradle_task_paths_need_review")
        if any("/src/main/" in "/" + f for f in support_files):
            flags.append("test_patch_touches_main_sources")
        if changed_lines(gold) > MAX_GOLD_LINES:
            flags.append("gold_over_1000_lines")
        if len(gold_files) > MAX_GOLD_FILES:
            flags.append("gold_over_20_files")
        if len(problem.split()) < MIN_PROBLEM_WORDS:
            flags.append("problem_statement_short")
        if any(f.startswith("android/") for f in gold_files + test_files):
            flags.append("touches_android_variant")
        if created and created[:4] < "2025":
            flags.append("likely_in_training_data")
        if created is None:
            flags.append("date_unknown")

        test_cmd = offline_test_command(tool, tests)
        meta = {
            "instance_id": iid,
            "repository": repo,
            "pull_number": pr,
            "linked_issues": issues,
            "base_commit": r["base_commit"],
            "created_at": created,
            "source_benchmark": source,
            "task_category": None if blank(r.get("task_category")) else r["task_category"],
            "environment": {
                "jdk": jdk,
                "build_tool": tool,
                "environment_hint": f"jdk{jdk}" if jdk else None,
                "upstream_docker_image": image if image.startswith("mswebench") else None,
            },
            "tests": {
                "classes": tests,
                "support_files": support_files,
                "test_command": test_cmd,
                "test_report_globs": report_globs(tool),
                # Upstream lists are kept for comparison only; Phase 5 validation recomputes them.
                "upstream_fail_to_pass": parse_list(r.get("F2P")),
                "upstream_pass_to_pass": parse_list(r.get("P2P")),
                "upstream_build_command": upstream_build_command(cmd) or None,
            },
            "gold": {"files": gold_files, "changed_lines": changed_lines(gold)},
            "hints_text": None if blank(r.get("hints_text")) else dedupe_issue_text(r["hints_text"]),
            "review_flags": flags,
        }

        tdir = out / "exports" / slug(repo) / iid
        tdir.mkdir(parents=True, exist_ok=True)
        (tdir / "problem_statement.md").write_text(problem + "\n", encoding="utf-8")
        (tdir / "gold.patch").write_text(gold if gold.endswith("\n") else gold + "\n", encoding="utf-8")
        (tdir / "test.patch").write_text(test if test.endswith("\n") else test + "\n", encoding="utf-8")
        (tdir / "metadata.json").write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")

        manifest.append(
            {
                "instance_id": iid,
                "repository": repo,
                "task_dir": str(tdir.relative_to(out)),
                "source_benchmark": source,
                "created_at": created,
                "jdk": jdk,
                "build_tool": tool,
                "test_classes": [t["fqcn"] for t in tests],
                "gold_changed_lines": meta["gold"]["changed_lines"],
                "gold_files": len(gold_files),
                "phase1_shortlist": repo in PHASE1_SHORTLIST,
                "review_flags": flags,
            }
        )

    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    write_configs(manifest, out, ai4i_root)
    write_summary(manifest, out)
    return {"tasks": len(manifest)}


def write_configs(manifest: list[dict], out: Path, ai4i_root: str) -> None:
    """One config per (repo, JDK), following the template in the Java plan (Phase 3)."""
    groups = defaultdict(list)
    for t in manifest:
        groups[(t["repository"], t["jdk"] or "unknown", t["build_tool"])].append(t)
    cdir = out / "configs"
    cdir.mkdir(exist_ok=True)
    for (repo, jdk, tool), tasks in sorted(groups.items()):
        name = f"{slug(repo)}-tddbench-jdk{jdk}"
        if tool == "gradle":
            stages = [
                {"stage": "configure", "arguments": ["gradle", "--offline", "--version"]},
                {"stage": "build", "arguments": ["gradle", "--offline", "testClasses"]},
                {"stage": "test", "arguments": ["gradle", "--offline", "--continue", "test"],
                 "test_report_globs": report_globs(tool)},
            ]
        else:
            stages = [
                {"stage": "configure", "arguments": ["mvn", "-o", "-q", "--version"]},
                {"stage": "build", "arguments": ["mvn", "-o", "-B", "test-compile", "-T", "{jobs}"]},
                {"stage": "test", "arguments": ["mvn", "-o", "-B", "test", "-fae"],
                 "test_report_globs": report_globs(tool)},
            ]
        cfg = {
            "name": name,
            "tasks_root": f"{ai4i_root}/exports/{slug(repo)}",
            "task_ids": sorted(t["instance_id"] for t in tasks),
            "image": f"{ai4i_root}/singularity/images/java-ubuntu22.04-jdk{jdk}.sif",
            "expected_image_sha256": "<fill after apptainer build>",
            "build_profile": "commands",
            "repository": {"allow_network": False},
            "validation": {"repetitions": 3, "toolchain_profiles": ["system-native"]},
            "build_commands": stages,
            "_note": (
                "Full-module test stage as in the plan template. Each task's targeted, offline "
                "command (only the classes touched by test.patch) is in metadata.json "
                "tests.test_command; use it if the validator supports per-task commands."
            ),
        }
        (cdir / f"{name}.json").write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")


def write_summary(manifest: list[dict], out: Path) -> None:
    by_repo = defaultdict(list)
    for t in manifest:
        by_repo[t["repository"]].append(t)
    flags = Counter(f for t in manifest for f in t["review_flags"])
    lines = [
        "# TDD-Bench-Java converted to RepairBench task folders",
        "",
        f"{len(manifest)} tasks from {len(by_repo)} repositories.",
        "",
        "| Repo | Tasks | Source | Build | JDK | Dates | Shortlist |",
        "|---|---:|---|---|---|---|---|",
    ]
    for repo, ts in sorted(by_repo.items(), key=lambda kv: -len(kv[1])):
        dates = sorted(t["created_at"][:10] for t in ts if t["created_at"])
        span = f"{dates[0][:7]} – {dates[-1][:7]}" if dates else "not given"
        lines.append(
            f"| {repo} | {len(ts)} | {', '.join(sorted({t['source_benchmark'] for t in ts}))} | "
            f"{', '.join(sorted({t['build_tool'] for t in ts}))} | "
            f"{', '.join(sorted({t['jdk'] or '?' for t in ts}))} | {span} | "
            f"{'yes' if ts[0]['phase1_shortlist'] else ''} |"
        )
    lines += ["", "## Review flags", "", "| Flag | Tasks |", "|---|---:|"]
    lines += [f"| `{f}` | {n} |" for f, n in flags.most_common()]
    clean = [t for t in manifest if t["phase1_shortlist"] and t["jdk"] and t["test_classes"]
             and not {"gold_over_1000_lines", "gold_over_20_files", "problem_statement_short"} & set(t["review_flags"])]
    lines += [
        "",
        f"Shortlist tasks with a known JDK, detected test classes and within review limits: **{len(clean)}**.",
        "",
        "Every dated task is from before 2025, so all carry `likely_in_training_data`: use them to bring up",
        "the Java runtime and harness, not for contamination-safe Pass@1.",
    ]
    (out / "SUMMARY.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--csv", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--ai4i-root", default="${AI4I_ROOT}")
    a = ap.parse_args()
    res = convert(a.csv, a.out, a.ai4i_root)
    print(f"converted {res['tasks']} tasks into {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
