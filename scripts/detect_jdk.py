#!/usr/bin/env python3
"""Infer a JDK for tasks whose CSV row does not state one (the Multi-SWE-bench rows).

Reads the build files at each task's base commit from the mirror (no checkout):
pom.xml (maven.compiler.release/source/target, java.version, javac.src.version, the
compiler plugin's <release>/<source>), build.gradle(.kts) and gradle.properties
(sourceCompatibility, JavaVersion.VERSION_x, toolchain languageVersion) and the Gradle
wrapper version, which limits the newest JDK that can run the build.

The chosen JDK is the smallest available image (8, 11, 17, 21) that is at least the
source level and runs the build tool. It is only the FIRST profile: validate_task.sh
still tries the others if the ORACLE run fails (ORACLE-first, as in the C/C++ pipeline).

Updates metadata.json (environment.jdk, environment.jdk_inferred_from), the manifest,
the per-repo configs and SUMMARY.md.

    python3 detect_jdk.py <out_dir> <mirrors_dir> [--all]   # --all also re-checks stated JDKs
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_tddbench import write_configs, write_summary  # noqa: E402

IMAGES = [8, 11, 17, 21]
# Highest JDK a given Gradle major.minor can RUN on (from Gradle's compatibility matrix).
# Gradle < 5.0 -> JDK 8 (of our images); 5.0-7.2 -> 11; 7.3-8.4 -> 17; 8.5+ -> 21.
GRADLE_MAX_JDK = [((5, 0), 8), ((7, 3), 11), ((8, 5), 17), ((99, 0), 21)]


def show(mirror: Path, base: str, path: str) -> str | None:
    r = subprocess.run(["git", "-C", str(mirror), "show", f"{base}:{path}"], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def level(v: str) -> int | None:
    v = v.strip().strip("'\"")
    m = re.match(r"^(?:1\.)?(\d+)", v)
    return int(m.group(1)) if m else None


def from_pom(text: str) -> list[tuple[int, str]]:
    found = []
    for tag in ("maven.compiler.release", "maven.compiler.source", "maven.compiler.target",
                "java.version", "javac.src.version", "javac.target.version", "release", "source", "target"):
        for m in re.finditer(rf"<{re.escape(tag)}>\s*([^<$]+?)\s*</{re.escape(tag)}>", text):
            lv = level(m.group(1))
            if lv and 5 <= lv <= 25:
                found.append((lv, f"pom.xml <{tag}>"))
    return found


def from_gradle(text: str) -> list[tuple[int, str]]:
    found = []
    # Only real settings count; a bare JavaVersion.VERSION_17 in an `if` is not a requirement.
    pats = [r"(?:source|target)Compatibility\s*=?\s*['\"]?(?:JavaVersion\.VERSION_)?([0-9_.]+)",
            r"languageVersion(?:\.set)?\s*[=(]\s*JavaLanguageVersion\.of\(\s*(\d+)\s*\)",
            r"options\.release(?:\.set)?\s*[=(]\s*(\d+)",
            r"jvmToolchain\(\s*(\d+)\s*\)"]
    for p in pats:
        for m in re.finditer(p, text):
            lv = level(m.group(1).replace("_", "."))
            if lv and 5 <= lv <= 25:
                found.append((lv, "gradle: " + m.group(0)[:60]))
    return found


def gradle_version(text: str | None) -> tuple[int, int] | None:
    if not text:
        return None
    m = re.search(r"gradle-(\d+)\.(\d+)", text)
    return (int(m.group(1)), int(m.group(2))) if m else None


def choose(mirror: Path, base: str, tool: str) -> tuple[int | None, list[str]]:
    evidence: list[tuple[int, str]] = []
    if tool == "maven":
        pom = show(mirror, base, "pom.xml")
        if pom:
            evidence += from_pom(pom)
    else:
        # Root build script, gradle.properties, and shared scripts under gradle/ and buildSrc/
        # (Mockito, for example, sets Java 11 in gradle/java-library.gradle).
        files = subprocess.run(["git", "-C", str(mirror), "ls-tree", "-r", "--name-only", base],
                               capture_output=True, text=True).stdout.splitlines()
        wanted = [f for f in files if f in ("build.gradle", "build.gradle.kts", "gradle.properties")
                  or (re.match(r"^(gradle|buildSrc)/", f) and re.search(r"\.gradle(\.kts)?$|\.properties$", f))]
        for f in wanted[:60]:
            t = show(mirror, base, f)
            if t:
                evidence += [(lv, f"{f}: {e.split(': ', 1)[1]}") for lv, e in from_gradle(t)]
    need = max([lv for lv, _ in evidence], default=8)
    need = max(need, 8)
    cap = 21
    gv = gradle_version(show(mirror, base, "gradle/wrapper/gradle-wrapper.properties")) if tool == "gradle" else None
    if gv:
        cap = next(mx for ver, mx in GRADLE_MAX_JDK if gv < ver)
    choices = [j for j in IMAGES if need <= j <= cap] or [j for j in IMAGES if j >= need] or [21]
    notes = [e for _, e in evidence][:6]
    if gv:
        notes.append(f"gradle wrapper {gv[0]}.{gv[1]} runs on JDK <= {cap}")
    return choices[0], notes


def main() -> int:
    out, mirrors = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    redo_all = "--all" in sys.argv
    manifest_path = out / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    changed = 0
    for e in manifest:
        task = out / e["task_dir"]
        meta_path = task / "metadata.json"
        meta = json.loads(meta_path.read_text())
        env = meta["environment"]
        if env.get("jdk") and not redo_all and not env.get("jdk_inferred_from"):
            continue
        mirror = mirrors / (e["repository"].replace("/", "__") + ".git")
        if not mirror.exists():
            print(f"{e['instance_id']}: no mirror (run normalize_patches.py first)")
            continue
        jdk, notes = choose(mirror, meta["base_commit"], env["build_tool"])
        if env.get("jdk") and not env.get("jdk_inferred_from"):
            if str(jdk) != str(env["jdk"]):
                print(f"{e['instance_id']}: stated jdk {env['jdk']}, build files suggest {jdk}")
            continue
        env["jdk"] = str(jdk)
        env["environment_hint"] = f"jdk{jdk}"
        env["jdk_inferred_from"] = notes or ["no source level found; default 8"]
        meta["review_flags"] = [f for f in meta["review_flags"] if f != "jdk_unknown"]
        if "jdk_inferred" not in meta["review_flags"]:
            meta["review_flags"].append("jdk_inferred")
        meta_path.write_text(json.dumps(meta, indent=2) + "\n")
        e["jdk"], e["review_flags"] = str(jdk), meta["review_flags"]
        changed += 1
        print(f"{e['instance_id']}: jdk {jdk}  ({'; '.join(env['jdk_inferred_from'])})")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    for old in (out / "configs").glob("*-tddbench-jdkunknown.json"):
        old.unlink()
    ai4i = "${AI4I_ROOT}"
    cfgs = list((out / "configs").glob("*.json"))
    if cfgs:
        ai4i = json.loads(cfgs[0].read_text())["tasks_root"].split("/exports/")[0]
    write_configs(manifest, out, ai4i)
    write_summary(manifest, out)
    print(f"inferred a JDK for {changed} tasks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
