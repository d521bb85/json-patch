#!/usr/bin/env python3
"""Runs every implementation over every workload and prints a comparison.

    python3 bench/run.py <data directory> <milliseconds per workload> [implementation...]

Implementations are compiled first with `build.sh`. Each one's final output is
compared with the expected result, so a number only appears if it is correct.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

WORKLOADS = ["small", "medium", "large", "pretty", "keyed", "many_ops", "twitter", "citm_catalog"]


def main():
    data = Path(sys.argv[1]).resolve()
    millis = sys.argv[2]
    bin_dir = Path(os.environ.get("BENCH_BIN", data / "bin"))
    (data / "out").mkdir(exist_ok=True)

    commands = {
        "zig": ["zig", "build", "bench", "-Doptimize=ReleaseFast", "--", str(data), millis],
        "yyjson": [str(bin_dir / "yyjson"), str(data), millis],
        "rust": [str(bin_dir / "rust"), str(data), millis],
        "go": [str(bin_dir / "go"), str(data), millis],
        "node": ["node", "bench/compare/node/main.js", str(data), millis],
    }
    selected = sys.argv[3:] or list(commands)

    results = {}
    for impl in selected:
        output = subprocess.run(commands[impl] + WORKLOADS, check=True, capture_output=True, text=True).stdout
        for line in output.splitlines():
            parts = line.split()
            key = impl if len(parts) == 2 else "zig-" + parts[1]
            results.setdefault(parts[0], {})[key] = None if parts[-1] == "FAILED" else int(parts[-1])

    def canonical(value):
        # Numbers are compared by value: 5755.0 and 5755 are the same number.
        if isinstance(value, dict):
            return {k: canonical(v) for k, v in value.items()}
        if isinstance(value, list):
            return [canonical(v) for v in value]
        if isinstance(value, float) and value.is_integer():
            return int(value)
        return value

    def same(a, b):
        return canonical(a) == canonical(b)

    order = ["zig-baseline", "zig-full", "zig-trusted", "zig-reuse"]
    columns = sorted({k for r in results.values() for k in r}, key=lambda k: order.index(k) if k in order else 9)
    print("%-14s" % "workload" + "".join("%14s" % c for c in columns) + "    (microseconds, median)")
    for name, row in results.items():
        expected = json.loads((data / (name + ".expected.json")).read_text(encoding="utf-8"))
        cells = []
        for column in columns:
            if column not in row:
                cells.append("%14s" % "-")
                continue
            if row[column] is None:
                cells.append("%14s" % "rejected")
                continue
            actual = json.loads((data / "out" / (column + "." + name + ".json")).read_text(encoding="utf-8"))
            mark = "" if same(actual, expected) else "!WRONG"
            cells.append("%14s" % ("%.2f%s" % (row[column] / 1000, mark)))
        print("%-14s" % name + "".join(cells))


if __name__ == "__main__":
    main()
