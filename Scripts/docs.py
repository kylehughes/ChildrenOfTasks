"""Build static DocC using the installed Swift/DocC tools; no package plugins."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

MODULES = ['ChildrenOfTasks']
BASE_PATH = 'ChildrenOfTasks'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Documentation output already exists; choose a fresh output")
    subprocess.run(["swift", "build"], check=True, timeout=600)
    # SwiftPM extracts symbol graphs with the package's real graph and settings.
    extraction = subprocess.check_output(["swift", "package", "dump-symbol-graph"], text=True, timeout=600)
    print(extraction, end="")
    locations = [line.removeprefix("Files written to ") for line in extraction.splitlines() if line.startswith("Files written to ")]
    if len(locations) != 1:
        raise ValueError("SwiftPM did not identify one symbol graph output directory")
    graphs = Path(locations[0])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="docc-", dir=args.output.parent))
    try:
        archives = []
        for module in MODULES:
            selected = scratch / module
            selected.mkdir()
            matches = list(graphs.glob(module + ".symbols.json")) + list(graphs.glob(module + "@*.symbols.json"))
            if not matches:
                raise ValueError("No public symbol graph for " + module)
            for path in matches:
                shutil.copyfile(path, selected / path.name)
            catalog = Path("Documentation/" + module + ".docc")
            if not catalog.is_dir():
                raise ValueError("Expected documentation catalog: " + str(catalog))
            archive = scratch / (module + ".doccarchive")
            subprocess.run(["xcrun", "docc", "convert", str(catalog), "--additional-symbol-graph-dir", str(selected),
                            "--output-path", str(archive), "--hosting-base-path", BASE_PATH,
                            "--transform-for-static-hosting", "--warnings-as-errors"], check=True, timeout=600)
            archives.append(archive)
        if len(archives) == 1:
            shutil.copytree(archives[0], args.output)
        else:
            subprocess.run(["xcrun", "docc", "merge"] + [str(path) for path in archives]
                           + ["--output-path", str(args.output)], check=True, timeout=600)
        destination = "/" + BASE_PATH.strip("/") + "/documentation/" + (MODULES[0].lower() + "/" if len(MODULES) == 1 else "")
        (args.output / "index.html").write_text('<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=' + destination + '"><a href="' + destination + '">Documentation</a>\n')
        (args.output / ".nojekyll").touch()
        print(json.dumps({"base_path": BASE_PATH, "modules": MODULES, "output": str(args.output)}))
    finally:
        shutil.rmtree(scratch)


if __name__ == "__main__":
    main()
