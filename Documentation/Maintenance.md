# Maintenance

Run verification from the repository root with Xcode 27.1 selected. The workflows target `kylehughes/ChildrenOfTasks` and publish [DocC documentation](https://kylehughes.github.io/ChildrenOfTasks/) through GitHub Pages.

## Runner and local tools

The workflows use GitHub's hosted `xcode-27` arm64 image and select `/Applications/Xcode_27.1.app/Contents/Developer`. The [observed image manifest](https://github.com/actions/runner-images/blob/xcode-27-arm64/20261023.0307/images/macos/xcode-27-arm64-Readme.md) lists Xcode 27.1 build 27A9275 at that path, Python 3, and the iOS 27.0 Simulator runtime. Each build job prints the selected Xcode version and rejects a compiler other than Swift 6.4. Local Xcode application filenames can differ; select the local installation before running the same checks.

The simulator helper also requires the `com.apple.CoreSimulator.SimDeviceType.iPhone-17` device type. `.github/actionlint.yaml` declares the hosted runner label for the installed linter.

Use an isolated runner for pull requests because workflow jobs execute candidate code. Keep publishing credentials out of the candidate build environment. Checkout disables persisted Git credentials, and candidate jobs have read-only repository permissions. No cache is configured.

Observe the selected tools before running checks:

```sh
xcode-select -p
swift --version
swift format --version
xcrun --find docc
xcrun simctl list runtimes
```

## Runtime validation

The library declares iOS 16.4 and macOS 13 deployment targets. Verify compilation and linking separately from runtime execution. Record the source revision, toolchain, executable identity, runtime version, destination, and results for each runtime check.

The Swift Testing simulator host requires iOS 17. Exercising iOS 16.4 requires a compatible minimal host or device; running tests on a newer simulator does not establish behavior on that oldest-runtime path.

## Verification

Run the same checks used by CI:

```sh
swift build
python3 Scripts/check-tests.py
python3 Scripts/check-compiler.py
bash Scripts/check-consumer.sh
swift format lint --strict --recursive Package.swift Sources Tests Integration Benchmarks
python3 Scripts/Simulator/simulator.py \
    --runtime com.apple.CoreSimulator.SimRuntime.iOS-27-0 \
    --floor 16.4 \
    --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

Also run optimized tests with `python3 Scripts/check-tests.py --configuration release` when changing behavior that depends on optimization. The host test helper retains expected selections and xUnit output in `.build/test-observations-*`. It rejects missing, duplicate, skipped, and failed tests. Compiler checks distinguish expected source rejections from known compiler crashes. The consumer script imports the public product from a separate package.

The Simulator helper creates one owned device, executes the unchanged package graph, and deletes that device after success or failure. It uses standalone execution without booting the device. Raw versioned discovery/execution streams, expected selections, destination and SDK facts, command logs, and cleanup receipts remain in `.build/simulator-*`. A failed or ambiguous creation response requires inspection of `creation-intent.json` and `commands.jsonl` before another attempt. `--device EXACT_UDID` instead preserves an existing device.

[CI](../.github/workflows/ci.yml) runs on pushes, pull requests, and manual dispatch. Its host job checks compilation, individual tests, compiler fixtures, public consumption, formatting, and DocC. A second job checks Simulator execution. Both upload test observations even after failure. The stable `Required checks` gate always runs and accepts only successful results from both jobs. Repository rules requiring that check must be configured separately.

Candidate jobs have 30-minute bounds, individual commands generally have 15-minute bounds, and helper subprocesses have their own bounds. These are initial limits; hosted duration and cost have not been measured. Revisit them after observing real runs. Superseded CI runs are canceled; release runs are serialized without canceling earlier runs.

## Static documentation and Pages

Build into an absent output directory:

```sh
mkdir -p .build
DOCS_RUN=$(mktemp -d .build/docs-preview.XXXXXX)
python3 Scripts/docs.py --output "$DOCS_RUN/site"
```

The static entry point is `/ChildrenOfTasks/documentation/childrenoftasks/`. Mount the output at `/ChildrenOfTasks/` when previewing it; serving the directory at `/` breaks its absolute asset paths. Inspect the module page, a symbol deep link, `index/index.json`, and referenced JavaScript/CSS assets. The command refuses to overwrite an existing output.

The [Documentation workflow](../.github/workflows/documentation.yml) runs only through `workflow_dispatch` and has no custom inputs. Dispatch builds and deploys the site, so it is a publication operation. Before dispatch, confirm the repository's Pages configuration, intended audience, and destination privacy. A private repository alone does not establish private Pages access. Do not dispatch confidential documentation until the destination's access controls are confirmed.

The build job uses read-only repository permissions and uploads `documentation-site`. The separate deployment job consumes that artifact, has only `pages: write` and `id-token: write`, and targets the `github-pages` environment. Configure any required environment reviewers and Pages settings before dispatch. The deployment job does not check out or run candidate code. Observe the resulting deployment URL and inspect its content and deep links before recording hosted success.

## Release

The [Release workflow](../.github/workflows/release.yml) is manual. It publishes a source archive, not prebuilt library binaries. Select the repository's default branch as the workflow source ref. Its exact dispatch commit must already contain the intended source, tests, documentation, and workflow; uncommitted local files cannot be released.

Before publishing, record verification results for the exact candidate, including the runtimes exercised and any explicitly accepted validation gaps. The prepared workflow runs iOS 27 simulator tests; it does not collect oldest-runtime evidence. Confirm the release version and license policy.

The dispatch inputs are:

| Input | Value |
| --- | --- |
| `candidate` | The exact lowercase 40-character SHA of the default-branch dispatch commit. It must also match the workflow SHA. |
| `version` | A semantic version without `v`, such as `1.2.3`; the tag becomes `v1.2.3`. No version is selected by this preparation. |
| `notes` | Supplied release notes; required unless generated notes are explicitly selected. |
| `generated_notes` | Defaults to `false`. Set `true` only when generated notes are intended. |
| `publish` | Defaults to `false`. Leave false for validation and archive preparation; true requests publication. |

Validation rejects an existing tag and any matching draft or published release. Read-only jobs check out the exact candidate, rerun the selected checks, and upload its `git archive` bytes with a SHA-256 digest. The privileged publisher downloads only that artifact, rechecks candidate and remote identities, verifies the digest, creates a draft, checks the uploaded asset's server digest, then publishes and observes the final tag. It never checks out or executes candidate code or archive contents.

Setting `publish` to true requires authorization for the exact destination, candidate, version, and notes choice. The workflow file and its defaults do not grant that authority. A validation-only run does not authorize a later publication dispatch, whose candidate and checks must be observed again.

After a failed or uncertain publishing request, inspect releases, assets, and tags before dispatching again. Preserve the failed run. Do not move a tag, replace an asset, or retry an unknown write to force success. Stop if the remote outcome remains unknown. A release is complete only after its candidate, asset digest, published state, and final tag have been observed.
