#!/usr/bin/env python3
"""Evaluates an Autobahn|Testsuite fuzzingclient report.

Usage: check_report.py <reports-dir>/index.json

Exits non-zero if any executed case reports a behavior or close behavior other
than OK / INFORMATIONAL / UNIMPLEMENTED, and prints the offending cases.
"""

import json
import sys

ACCEPTED = {"OK", "INFORMATIONAL", "UNIMPLEMENTED"}


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    with open(sys.argv[1]) as handle:
        report = json.load(handle)
    failures = []
    total = 0
    for agent, cases in report.items():
        for case, result in sorted(cases.items()):
            total += 1
            behavior = result.get("behavior", "?")
            close = result.get("behaviorClose", "?")
            if behavior not in ACCEPTED or close not in ACCEPTED:
                failures.append(f"{agent} {case}: behavior={behavior} close={close}")
    if failures:
        print(f"FAIL: {len(failures)} of {total} cases:")
        for line in failures:
            print(" ", line)
        return 1
    print(f"PASS: {total} Autobahn cases (behavior and close behavior all accepted)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
