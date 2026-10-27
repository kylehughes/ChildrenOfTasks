#!/usr/bin/env python3
"""Build isolated optimized cost fixtures and preserve reproducible measurements."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    try:
        return subprocess.run(command, check=True, text=True, **kwargs)
    except subprocess.CalledProcessError as error:
        if error.stderr:
            print(error.stderr)
        raise


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT.parent / "ChildrenOfTasks Implementation Evidence" / "costs")
    parser.add_argument("--counts", type=int, nargs="+", default=[100, 1000, 10000])
    parser.add_argument("--samples", type=int, default=5)
    args = parser.parse_args()
    if args.samples < 1 or any(count < 1 for count in args.counts):
        parser.error("counts and samples must be positive")
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    build = output / "build"
    build.mkdir(exist_ok=True)
    sources = sorted((ROOT / "Sources" / "ChildrenOfTasks").glob("*.swift"))
    inputs = sources + sorted((ROOT / "Benchmarks").glob("*.swift")) + [Path(__file__).resolve()]
    identity = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
    flags = ["-O", "-swift-version", "6", "-strict-concurrency=complete", "-target", "arm64-apple-macosx13.0"]
    commands = []
    for module, files in [("ChildrenOfTasks", sources), ("Baseline", [ROOT / "Benchmarks" / "Control.swift"])]:
        command = ["xcrun", "swiftc", *flags, "-emit-library", "-emit-module", "-module-name", module,
                   *map(str, files), "-emit-module-path", str(build / f"{module}.swiftmodule"),
                   "-o", str(build / f"lib{module}.dylib")]
        commands.append(command)
        run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    executable = build / "costs"
    command = ["xcrun", "swiftc", *flags, "-parse-as-library", str(ROOT / "Benchmarks" / "Costs.swift"),
               "-I", str(build), "-L", str(build), "-lChildrenOfTasks", "-lBaseline", "-Xlinker", "-rpath",
               "-Xlinker", str(build), "-o", str(executable)]
    commands.append(command)
    run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    environment = {
        "compiler": run(["xcrun", "swiftc", "--version"], capture_output=True).stdout,
        "os": run(["sw_vers"], capture_output=True).stdout,
        "hardware": run(["sysctl", "-n", "hw.model", "hw.memsize", "machdep.cpu.brand_string"], capture_output=True).stdout,
        "sdk": run(["xcrun", "--show-sdk-path"], capture_output=True).stdout.strip(),
        "sdk_version": run(["xcrun", "--show-sdk-version"], capture_output=True).stdout.strip(),
        "xcode": run(["xcodebuild", "-version"], capture_output=True).stdout,
        "architecture": platform.machine(), "optimization": "-O, separate dynamically linked modules; no WMO or LTO",
        "features": "Swift 6; complete strict concurrency; no upcoming/experimental features or default-isolation override",
    }
    rows = []
    for workload in ["creation-observation", "fanout", "retained-handles", "short-lived"]:
        for count in args.counts:
            for backend in ["package", "baseline"]:
                stem = f"{workload}-{count}-{backend}"
                command = ["/usr/bin/time", "-l", str(executable), backend, workload, str(count), str(args.samples)]
                commands.append(command)
                result = run(command, capture_output=True, timeout=180)
                (output / f"{stem}.json").write_text(result.stdout)
                (output / f"{stem}.time.txt").write_text(result.stderr)
                samples = json.loads(result.stdout)
                durations = [sample["milliseconds"] for sample in samples]
                peak_line = next((line.strip() for line in result.stderr.splitlines() if "maximum resident set size" in line), None)
                rows.append({"backend": backend, "workload": workload, "count": count,
                             "median_ms": statistics.median(durations), "min_ms": min(durations), "max_ms": max(durations),
                             "peak_rss_bytes": int(peak_line.split()[0]) if peak_line else None,
                             "samples": samples})
                print(f"{stem}: median {statistics.median(durations):.3f} ms", flush=True)
    after = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
    if identity != after:
        raise RuntimeError("Benchmark inputs changed during measurement; rerun the changed candidate")
    report = {"started_utc": started, "environment": environment,
              "source_sha256": identity, "commands": commands, "samples_per_case": args.samples,
              "warmups_per_process": 1, "processes": len(rows), "rows": rows,
              "artifact_sha256": {path.name: digest(path) for path in [executable, build / "libChildrenOfTasks.dylib", build / "libBaseline.dylib"]},
              "limits": ["RSS is resident process memory, not live allocation bytes.",
                         "time -l peak covers warmup, all samples, runtime, and shared modules.",
                         "Live counts instrument payloads only, not native tasks, cells, or continuations.",
                         "malloc_zone_statistics sums current live blocks/bytes across zones, not cumulative allocations or allocations attributed to ChildrenOfTasks.",
                         "Fanout is mixed pending/completed readers; it does not guarantee all attach before publication."]}
    (output / "costs.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Evidence: {output / 'costs.json'}")


if __name__ == "__main__":
    main()
