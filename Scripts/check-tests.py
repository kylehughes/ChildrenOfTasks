"""Run Swift Testing and require nonempty, complete individual observations."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def observe(selection, report):
    if not selection or len(selection) != len(set(selection)):
        raise ValueError("Missing or duplicate selected tests")
    root = ET.fromstring(report)
    cases = root.findall(".//testcase")
    observed = [case.get("classname", "") + "/" + case.get("name", "") for case in cases]
    if sorted(observed) != sorted(selection):
        raise ValueError("Test execution differs from selected individual tests")
    if any(case.find(kind) is not None for case in cases for kind in ("skipped", "failure", "error")):
        raise ValueError("A selected test was skipped or failed")
    return observed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    args = parser.parse_args()
    common = ["--configuration", args.configuration]
    manifest = json.loads(subprocess.check_output(["swift", "package", "dump-package"], text=True, timeout=120))
    targets = [target["name"] for target in manifest["targets"] if target["type"] == "test"]
    selected = subprocess.check_output(["swift", "test", *common, "list"], text=True, timeout=600).splitlines()
    selected = [line.strip() for line in selected if line.strip()]
    selected = [line if "/" in line else "/".join(line.rsplit(".", 1)) for line in selected]
    if not targets or any(not any(case.startswith(name + ".") or case.startswith(name + "/") for case in selected) for name in targets):
        raise ValueError("A test target has no selected tests")
    directory = Path(tempfile.mkdtemp(prefix="test-observations-", dir=".build"))
    (directory / "selection.json").write_text(json.dumps({"expected": selected}, indent=2) + "\n")
    report = directory / "results.xml"
    subprocess.run(["swift", "test", *common, "--xunit-output", str(report.resolve())], check=True, timeout=600)
    reports = list(directory.glob("*.xml"))
    if not reports:
        raise ValueError("Test execution produced no xUnit observations")
    combined = ET.Element("testsuites")
    for path in reports:
        document = ET.fromstring(path.read_bytes())
        for suite in document.findall(".//testsuite"):
            combined.append(suite)
    observed = observe(selected, ET.tostring(combined))
    (directory / "selection.json").write_text(json.dumps({"expected": selected, "observed": observed}, indent=2) + "\n")
    print(f"Passed {len(observed)} selected tests; observations: {directory}")


if __name__ == "__main__":
    main()
