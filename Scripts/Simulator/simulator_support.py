"""Portable SwiftPM/Swift Testing recipes shared with exported repositories."""
from __future__ import annotations

import json
from pathlib import Path
import re
import struct


def build_command(developer_dir, sdk, floor, *, package=".", scratch=".build/ios", configuration="debug", product=None):
    developer = Path(developer_dir)
    platform = developer / "Platforms/iPhoneSimulator.platform/Developer"
    # SwiftPM evaluates Package.swift for the host. SDKROOT would also leak into
    # its downstream linker; --sdk alone selects the target SDK explicitly.
    command = ["/usr/bin/env", "-u", "SDKROOT",
               str(developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"), "build", "--disable-sandbox",
               "--build-system", "native", "--toolchain", str(developer / "Toolchains/XcodeDefault.xctoolchain"),
               "--triple", f"arm64-apple-ios{floor or ''}-simulator", "--sdk", str(sdk),
               "--package-path", str(package), "--scratch-path", str(scratch), "--configuration", configuration,
               "-Xswiftc", "-F", "-Xswiftc", str(platform / "Library/Frameworks"),
               "-Xswiftc", "-I", "-Xswiftc", str(platform / "usr/lib"),
               # Clang's Darwin SDKInfo parser needs -isysroot. Swift's
               # --sysroot forwarding alone selects library paths but leaves
               # ld's SDK version at the deployment floor.
               "-Xswiftc", "-Xclang-linker", "-Xswiftc", "-isysroot",
               "-Xswiftc", "-Xclang-linker", "-Xswiftc", str(sdk),
               "-Xlinker", "-rpath", "-Xlinker", str(platform / "Library/Frameworks")]
    return command + (["--product", product] if product else ["--build-tests"])


def testing_runner_command(developer_dir, sdk, triple, *, source, output, module_cache):
    """Compile the trusted helper with the same explicit Simulator linker SDK."""
    developer = Path(developer_dir)
    frameworks = developer / "Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"
    return [str(developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"),
            "-parse-as-library", "-swift-version", "6", "-warnings-as-errors",
            "-target", triple, "-sdk", str(sdk), "-F", str(frameworks),
            "-Xclang-linker", "-isysroot", "-Xclang-linker", str(sdk),
            "-module-cache-path", str(module_cache),
            "-Xlinker", "-rpath", "-Xlinker", str(frameworks), str(source), "-o", str(output)]


def require_testing_runner_target(path, expected_target, selected_sdk):
    """Reject a helper with a different platform, deployment target, or SDK."""
    observed = require_binary_sdk(simulator_binary_target(path), selected_sdk)
    if observed["triple"] != expected_target["triple"]:
        raise ValueError("Trusted Simulator runner target differs from the package test binary")
    return observed


def validate_events(text, *, expected=None, discovery_targets=None):
    """Require actual nonempty selected test events, never infer success from exit."""
    records = [json.loads(line) for line in text.splitlines() if line.strip()]
    if not records or any(type(item) is not dict or type(item.get("version")) is not int or item.get("version") != 0 for item in records):
        raise ValueError("Missing or unsupported Swift Testing event stream")
    definitions, started, ended, events, suites = [], [], [], [], set()
    for item in records:
        payload = item.get("payload", {})
        if item.get("kind") == "test" and payload.get("kind") == "function":
            identity = payload.get("id")
            if not isinstance(identity, str) or not identity:
                raise ValueError("Malformed Swift Testing identity")
            definitions.append(identity)
        elif item.get("kind") == "test" and payload.get("kind") == "suite":
            suites.add(payload.get("id"))
        if item.get("kind") == "event":
            kind = payload.get("kind")
            events.append(kind)
            if kind == "testStarted":
                started.append(payload.get("testID"))
            if kind == "testEnded":
                ended.append(payload.get("testID"))
            if kind == "issueRecorded" and not payload.get("issue", {}).get("isKnown", False):
                raise ValueError("Swift Testing recorded an unexpected issue")
            if kind == "testSkipped":
                raise ValueError("Selected Simulator test was skipped")
    selected = sorted(set(definitions))
    if not selected or len(selected) != len(definitions):
        raise ValueError("No selected Simulator tests or duplicate definitions")
    if discovery_targets is not None:
        if any(not any(identity.startswith(target + ".") or identity.startswith(target + "/") for identity in selected)
               for target in discovery_targets):
            raise ValueError("Missing admitted Simulator test target")
        return selected
    started = [identity for identity in started if identity not in suites]
    ended = [identity for identity in ended if identity not in suites]
    if (expected is None or set(selected) != set(expected)
            or sorted(started) != sorted(expected) or sorted(ended) != sorted(expected)):
        raise ValueError("Simulator tests did not execute the exact frozen selection")
    if events.count("runStarted") != 1 or events.count("runEnded") != 1:
        raise ValueError("Incomplete Simulator test run")
    return selected


def exact_filter(identities):
    return "^(?:" + "|".join(re.escape(value) for value in identities) + ")$"


def simulator_binary_target(path):
    """Read the produced arm64 Mach-O target, without executing generated bytes."""
    with Path(path).open("rb") as source:
        header = source.read(32)
        if len(header) != 32 or struct.unpack_from("<I", header)[0] != 0xFEEDFACF:
            raise ValueError("Expected a thin arm64 Mach-O Simulator artifact")
        _, cpu, _, _, count, size, _, _ = struct.unpack("<8I", header)
        if cpu != 0x100000C or size > 16 * 1024 * 1024 or count > 65536:
            raise ValueError("Invalid Simulator Mach-O architecture or load-command bounds")
        commands = source.read(size)
    offset = 0
    for _ in range(count):
        if offset + 8 > len(commands):
            raise ValueError("Truncated Mach-O load commands")
        kind, length = struct.unpack_from("<II", commands, offset)
        if length < 8 or offset + length > len(commands):
            raise ValueError("Invalid Mach-O load command")
        if kind == 0x32 and length >= 24:
            platform, minimum, sdk = struct.unpack_from("<III", commands, offset + 8)
            if platform != 7:
                raise ValueError("Produced artifact is not an iOS Simulator binary")
            version = lambda value: f"{value >> 16}.{(value >> 8) & 255}.{value & 255}"
            floor = version(minimum)
            return {"platform": "ios-simulator", "minimum_version": floor,
                    "sdk_version": version(sdk), "triple": f"arm64-apple-ios{floor}-simulator"}
        offset += length
    raise ValueError("Simulator build target metadata is missing")


def require_binary_sdk(target, selected_version):
    def parts(value):
        values = tuple(int(item) for item in value.split("."))
        return values + (0,) * (3 - len(values))
    if parts(target["sdk_version"]) != parts(selected_version):
        raise ValueError("Simulator binary linked SDK differs from the frozen SDK selection")
    return target
