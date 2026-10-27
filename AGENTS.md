# Repository Guidelines

## Project Structure & Module Organization

ChildrenOfTasks is a single-library Swift package with no external dependencies.

- `Sources/ChildrenOfTasks/` contains the public API and internal result storage.
- `Tests/ChildrenOfTasksTests/` contains unit tests and shared async helpers; `Tests/CompilerFixtures/` separates positive cases, expected rejections, and known compiler crashes.
- `Integration/Consumer/` exercises the public product; `Benchmarks/` measures costs.
- `Documentation/ChildrenOfTasks.docc/` contains API documentation. `Scripts/` provides verification tools; `.github/workflows/` defines CI and publication.

Keep generated `.build/` output and ignored `Specification/` research inputs out of commits.

## Build, Test, and Development Commands

Select Xcode 27.1 with Swift 6.4 and run commands from the repository root:

- `swift build` — compile the library with warnings treated as errors.
- `python3 Scripts/check-tests.py` — run Swift Testing cases and verify discovery/execution results. Add `--configuration release` for optimization-sensitive changes.
- `python3 Scripts/check-compiler.py` — check compiler contracts and distinguish known crashes from expected rejections.
- `bash Scripts/check-consumer.sh` — validate consumption from a separate package.
- `swift format lint --strict --recursive Package.swift Sources Tests Integration Benchmarks` — enforce formatting.

See [Maintenance](Documentation/Maintenance.md) for simulator and DocC commands. Newer simulator execution does not establish iOS 16.4 runtime support.

## Coding Style & Naming Conventions

Use four-space indentation, UpperCamelCase types, and lowerCamelCase members. Name files by their primary type or topic; preserve existing declaration spacing. Document public APIs with `///`, including ownership and cancellation contracts.

Maintain Swift 6 strict concurrency. Preserve the borrowed `Children` capability, Sendable result handles, and scope-owned cancellation and joining.

## Testing Guidelines

Use Swift Testing (`@Suite`, `@Test`, `#expect`). Give test methods descriptive lowerCamelCase behavior names without a `test` prefix. Keep shared synchronization helpers in `TestSupport.swift`.

Use explicit readiness/completion signals for async tests; deadlines bound failures rather than establish ordering. Add regression coverage for changed behavior, particularly cancellation, error propagation, shared results, and scope exit. No numerical coverage threshold is configured.

## Commit & Pull Request Guidelines

Use short imperative commit subjects, such as `Fix Xcode selection on GitHub runners`; existing history uses no conventional-commit prefixes.

Source contributions are currently closed; bug reports are considered. For maintainer pull requests, describe the problem, resulting behavior, relevant issues, verification commands/results, and remaining limitations. Assign `kylehughes` and confirm CI's `Required checks` passes before merging.
