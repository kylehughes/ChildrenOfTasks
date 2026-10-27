"""Run selected Swift Testing cases on an explicit installed iOS runtime."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import subprocess
import uuid

from simulator_support import (build_command, exact_filter, validate_events, simulator_binary_target,
                               require_binary_sdk, testing_runner_command, require_testing_runner_target)


def run_command(command, *, root, scratch, environment, capture=True, extra=None):
    argv = list(map(str, command))
    try:
        result = subprocess.run(argv, cwd=root, env={**environment, **(extra or {})},
                                text=True, capture_output=capture, timeout=600)
    except subprocess.TimeoutExpired as error:
        # TimeoutExpired can carry bytes even when text=True. Retain partial output.
        text = lambda value: value.decode(errors="replace") if isinstance(value, bytes) else value
        with (scratch / "commands.jsonl").open("a") as log:
            log.write(json.dumps({"argv": argv, "exit": None, "timeout": error.timeout,
                                  "stdout": text(error.stdout), "stderr": text(error.stderr)}) + "\n")
        raise
    with (scratch / "commands.jsonl").open("a") as log:
        log.write(json.dumps({"argv": argv, "exit": result.returncode,
                              "stdout": result.stdout, "stderr": result.stderr}) + "\n")
    result.check_returncode()
    return result.stdout


@contextmanager
def destination(run, simctl, *, scratch, runtime, device_type, supplied=None):
    """Delete only the exact validated device returned by our successful create."""
    if supplied is not None:
        yield supplied
        return
    name = "Package tests " + uuid.uuid4().hex
    (scratch / "creation-intent.json").write_text(json.dumps({"name": name, "runtime": runtime, "type": device_type}))
    # One attempt only. Missing, failed or ambiguous responses need manual inspection.
    device_id = run([simctl, "create", name, device_type, runtime]).strip()
    if not re.fullmatch(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", device_id):
        raise ValueError("Ambiguous Simulator creation response; inspect creation intent and raw commands")
    failure = None
    try:
        yield device_id
    except BaseException as error:
        failure = error
        raise
    finally:
        cleanup = {"destination": device_id, "operation": "delete"}
        try:
            run([simctl, "delete", device_id])
        except BaseException as error:
            cleanup.update(status="failed", error=repr(error))
            (scratch / "cleanup.json").write_text(json.dumps(cleanup, indent=2) + "\n")
            if failure is None:
                raise
            failure.add_note("Simulator cleanup also failed: " + repr(error))
        else:
            cleanup.update(status="deleted")
            (scratch / "cleanup.json").write_text(json.dumps(cleanup, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--floor", required=True)
    parser.add_argument("--device-type", default="com.apple.CoreSimulator.SimDeviceType.iPhone-17")
    parser.add_argument("--device", help="Use this exact existing device without booting, erasing or deleting it")
    args = parser.parse_args()
    root = Path.cwd()
    here = Path(__file__).resolve().parent
    scratch = root / ".build" / ("simulator-" + uuid.uuid4().hex)
    scratch.mkdir(parents=True)
    environment = dict(os.environ)
    environment.pop("SDKROOT", None)

    def run(command, *, capture=True, extra=None):
        return run_command(command, root=root, scratch=scratch, environment=environment,
                           capture=capture, extra=extra)

    developer = Path(environment.get("DEVELOPER_DIR") or run(["xcode-select", "-p"]).strip())
    sdk = developer / "Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
    sdk_version = run(["xcrun", "--sdk", str(sdk), "--show-sdk-version"]).strip()
    sdk_build = run(["xcrun", "--sdk", str(sdk), "--show-sdk-build-version"]).strip()
    simctl = developer / "usr/bin/simctl"
    inventory = json.loads(run([simctl, "list", "--json"]))
    runtimes = [item for item in inventory["runtimes"] if item["identifier"] == args.runtime and item["isAvailable"]]
    if len(runtimes) != 1:
        raise ValueError("Selected installed runtime is unavailable or ambiguous")
    runtime = runtimes[0]
    manifest = json.loads(run(["swift", "package", "dump-package"]))
    targets = [target["name"] for target in manifest["targets"] if target["type"] == "test"]
    if not targets:
        raise ValueError("No test targets selected")
    # SwiftPM evaluates the unchanged manifest, retaining every dependency/setting.
    run(build_command(developer, sdk, args.floor, scratch=scratch / "build"))
    bundles = list((scratch / "build/arm64-apple-ios-simulator/debug").glob("*.xctest"))
    if len(bundles) != 1:
        raise ValueError("Expected one package test bundle")
    binaries = [item for item in (bundles[0] / "Contents/MacOS").iterdir() if item.is_file()]
    if len(binaries) != 1:
        raise ValueError("Ambiguous package test executable")
    target = require_binary_sdk(simulator_binary_target(binaries[0]), sdk_version)
    runner = scratch / "TestingRunner"
    run(testing_runner_command(developer, sdk, target["triple"], source=here / "simulator_runner.swift",
                               output=runner, module_cache=scratch / "modules"))
    require_testing_runner_target(runner, target, sdk_version)
    owned = args.device is None
    with destination(run, simctl, scratch=scratch, runtime=args.runtime,
                     device_type=args.device_type, supplied=args.device) as device_id:
        if owned:
            inventory = json.loads(run([simctl, "list", "--json"]))
        devices = [device for device in inventory["devices"].get(args.runtime, []) if device["udid"] == device_id and device.get("isAvailable")]
        if len(devices) != 1:
            raise ValueError("Exact destination is not available on the selected runtime")
        device = devices[0]
        observation = {"sdk_version": sdk_version, "sdk_build": sdk_build, "runtime": args.runtime,
                       "runtime_version": runtime["version"], "destination": device_id, "owned": owned,
                       "initial_state": device["state"], "booted_by_helper": False, "target": target}
        (scratch / "destination.json").write_text(json.dumps(observation, indent=2) + "\n")
        frameworks = developer / "Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"
        launch = [simctl, "spawn", "--standalone", device_id, "/usr/bin/env",
                  "DYLD_ROOT_PATH=" + runtime["runtimeRoot"], "DYLD_FRAMEWORK_PATH=" + str(frameworks),
                  "DYLD_LIBRARY_PATH=" + str(developer / "Platforms/iPhoneSimulator.platform/Developer/usr/lib"),
                  "PACKAGE_TEST_BUNDLE=" + str(binaries[0])]
        discovery, execution = scratch / "discovery.jsonl", scratch / "execution.jsonl"
        run(launch + ["PACKAGE_EVENT_STREAM_PATH=" + str(discovery), runner, "list",
                      "^(?:" + "|".join(re.escape(value) for value in targets) + r")[./]"])
        selected = validate_events(discovery.read_text(), discovery_targets=targets)
        (scratch / "selection.json").write_text(json.dumps({"expected": selected}, indent=2) + "\n")
        run(launch + ["PACKAGE_EVENT_STREAM_PATH=" + str(execution), runner, "run", exact_filter(selected)])
        observed = validate_events(execution.read_text(), expected=selected)
        observation.update(expected=selected, observed=observed)
        (scratch / "results.json").write_text(json.dumps(observation, indent=2) + "\n")
    print(f"Passed {len(observed)} selected iOS Simulator tests; observations: {scratch}")


if __name__ == "__main__":
    main()
