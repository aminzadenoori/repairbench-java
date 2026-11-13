#!/usr/bin/env python3
"""Read JUnit XML reports (Surefire or Gradle) and print {test_id: status} as JSON.

test_id is classname::name; status is one of passed, failed, error, skipped.
A test that appears more than once (reruns) keeps its worst status.

    python3 parse_junit.py <repo_dir> '**/target/surefire-reports/TEST-*.xml' [...]
"""
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

RANK = {"passed": 0, "skipped": 1, "failed": 2, "error": 3}


def main() -> int:
    root = Path(sys.argv[1])
    results: dict[str, str] = {}
    for glob in sys.argv[2:]:
        for f in sorted(root.glob(glob)):
            try:
                tree = ET.parse(f)
            except ET.ParseError:
                continue
            for case in tree.iter("testcase"):
                tid = f"{case.get('classname', '')}::{case.get('name', '')}"
                if case.find("error") is not None:
                    st = "error"
                elif case.find("failure") is not None:
                    st = "failed"
                elif case.find("skipped") is not None:
                    st = "skipped"
                else:
                    st = "passed"
                if RANK[st] >= RANK.get(results.get(tid, "passed"), 0) or tid not in results:
                    results[tid] = st
    json.dump(results, sys.stdout, indent=1, sort_keys=True)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
