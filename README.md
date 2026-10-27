# ChildrenOfTasks

[![Provenance: Software Factory](https://img.shields.io/badge/Provenance-Software_Factory-007AFF)](#provenance)
[![Platform Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2FChildrenOfTasks%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/kylehughes/ChildrenOfTasks)
[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2FChildrenOfTasks%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/kylehughes/ChildrenOfTasks)
[![Test](https://github.com/kylehughes/ChildrenOfTasks/actions/workflows/ci.yml/badge.svg)](https://github.com/kylehughes/ChildrenOfTasks/actions/workflows/ci.yml)

ChildrenOfTasks lets you pass pending work through ordinary Swift helpers while one enclosing scope owns cancellation and completion. Each `Child` preserves its operation's result and failure types.

Use it when independently started work needs to travel between helpers. A direct `await` suits sequential work; `async let` remains a good fit for a fixed pair of local operations.

## Quick start

An export starts loading its text and title, then passes both pending results to the rendering helper. The application supplies the two loading operations and its `ReadFailure` error type.

```swift
import ChildrenOfTasks

enum ReadFailure: Error {
    case unavailable
}

func prepareExport(
    readText: @escaping @Sendable () async throws(ReadFailure) -> String,
    readTitle: @escaping @Sendable () async -> String
) async throws(ReadFailure) -> String {
    try await withChildren { (children: borrowing Children) throws(ReadFailure) in
        let text = children.start(readText)
        let title = children.start(readTitle)

        return try await render(text, title: title)
    }
}

func render(
    _ text: Child<String, ReadFailure>,
    title: Child<String, Never>
) async throws(ReadFailure) -> String {
    let heading = await title.value()
    let content = try await text.value()

    return heading + "\n\n" + content
}
```

`start` submits work immediately to a native task group. It does not wait for a call to `value()`. The helper can choose when to observe each result without taking ownership of either producer's lifetime.

## Installation

The package is available in the private [kylehughes/ChildrenOfTasks](https://github.com/kylehughes/ChildrenOfTasks) repository and has no tagged release. Add a checkout as a local package dependency in Xcode, select the **ChildrenOfTasks** product, and import `ChildrenOfTasks`.

For a neighboring Swift package, replace the path below with the actual checkout path. The explicit dependency name keeps the product reference stable even when the checkout folder has another name:

```swift
.package(name: "ChildrenOfTasks", path: "../ChildrenOfTasks")
```

Add `.product(name: "ChildrenOfTasks", package: "ChildrenOfTasks")` to the consuming target's dependencies.

## Working with handles

`Children` is borrowed authority to start work in the current scope. A helper may borrow it and return a new handle. Keep that authority in the creating task: do not store it, capture it in another task, send it to another actor, consume it, or swap it with another scope.

`Child<Value, Failure>` is copyable and `Sendable`. Pass or store a handle, share it with concurrent readers, or return it from the body. Repeated reads observe the same stored outcome without running the operation again. Returning a handle from `withChildren` waits for its producer before the caller receives it.

Child values must be copyable and `Sendable`; reference-valued results retain their normal reference semantics. Typed failures stay typed, untyped throwing operations use `any Error`, and `Child<Value, Never>.value()` is nonthrowing. Combining unrelated errors is the caller's choice.

## Completion and cancellation

The body's outcome determines the scope's outcome. When the body returns or throws, `withChildren` cancels remaining work and joins every child before returning that value or error. A caught or ignored child failure does not fail the scope or cancel siblings.

| Situation | Behavior |
| --- | --- |
| Start after cancellation | The operation still executes with cancellation requested and publishes its own outcome. |
| Parent cancellation | Native structured cancellation reaches children; the body handles cancellation itself. |
| Canceled reader | `value()` keeps waiting for the producer's stored outcome. |
| Dropped handle | Its producer remains owned by the scope. |
| Success after cancellation | The success is preserved. |
| Child ignores cancellation | Scope exit waits until that child finishes. |

Cancellation is cooperative. A body or child that never finishes can prevent the scope from returning. A published result means the supplied operation has returned or thrown; only scope exit establishes that every wrapping task has been joined.

The body inherits the caller's actor isolation and may return actor-local, non-Sendable state. Child operations cross a task boundary and accept escaping `@Sendable` closures. Explicit actor-isolated operations retain their isolation; arbitrary child closure literals are not promised to inherit the caller's actor context.

## Compatibility

- Swift tools/compiler 6.4 and Swift 6 language mode, with complete strict concurrency checking.
- Library deployment targets: iOS 16.4 and macOS 13. The module uses the normal nonisolated default, without upcoming or experimental feature flags.
- Current validation uses Apple Swift 6.4 (`swiftlang-6.4.0.34.1`) from Xcode 27.1. iOS 16.4 compilation and linking, current macOS execution, and iOS 27 simulator execution are separate checks.
- **Actual iOS 16.4 execution is still required before release acceptance.** Newer simulator tests do not exercise that oldest-runtime path. The Swift Testing simulator host itself requires iOS 17; a compatible minimal host or device is needed for the 16.4 check. Execution on macOS 13 has not been established.

Swift 6.4 has known compiler crashes for some forbidden captures when the scope parameter is inferred. Use the explicit `(children: borrowing Children)` spelling shown above. The compiler fixtures retain those failures as known diagnostic defects, separately from expected rejection checks. Valid-use crashes or accepted authority escapes block support for an affected compiler. `value()` is a method because an earlier typed-throwing property probe also exposed a compiler defect.

## Costs and limits

Each scope creates group storage; each child adds a native task and actor-backed result cell. Suspended readers use continuations, and handles retain completed outcomes. Task-group completion records can accumulate until scope exit, so use a scope for a bounded operation rather than an indefinitely running spawning service.

There is no per-child cancellation, priority API, timeout, retry, stream, or result-combinator family. Waiting on a handle does not promise priority donation from an unrelated reader. No allocation-free or `async let` performance-equivalence claim is made. See [measured costs](Documentation/Performance.md).

## Documentation and maintenance

The [published DocC documentation](https://kylehughes.github.io/ChildrenOfTasks/) and [scope design](Documentation/ChildrenOfTasks.docc/ScopeLifetime.md) explain the API and its ownership boundary. Build and check with the selected Xcode toolchain:

```sh
swift build
swift test
swift test -c release
python3 Scripts/check-tests.py
python3 Scripts/check-compiler.py
bash Scripts/check-consumer.sh
swift format lint --strict --recursive Package.swift Sources Tests Integration Benchmarks
python3 Scripts/docs.py --output .build/site
```

The static site uses `/ChildrenOfTasks/documentation/childrenoftasks/` as its entry point. Serve `.build/site` mounted at `/ChildrenOfTasks/` when previewing its assets and deep links. Rebuild into a fresh output directory; the docs command refuses to overwrite an existing one.

[CI](.github/workflows/ci.yml) runs host tests, compiler checks, a public consumer, formatting, DocC, and an owned iOS simulator, then requires every selected job to succeed. The workflows use GitHub's `xcode-27` arm64 image, select Xcode 27.1, and require the iOS 27.0 runtime. See [Actions](https://github.com/kylehughes/ChildrenOfTasks/actions) for results on each commit. Run that simulator check locally with:

```sh
python3 Scripts/Simulator/simulator.py \
    --runtime com.apple.CoreSimulator.SimRuntime.iOS-27-0 \
    --floor 16.4 \
    --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17
```

[Documentation deployment](.github/workflows/documentation.yml) and [release](.github/workflows/release.yml) are manually dispatched. They separate read-only builds from artifact-only publishing. Release requires an exact candidate SHA, a version, and supplied notes by default; generated notes require an explicit choice. The DocC site is published on GitHub Pages; no release has been published. See [delivery maintenance](Documentation/Maintenance.md) before dispatching either publisher.

## Contributions

ChildrenOfTasks is not accepting source contributions at this time. Bug reports will be considered.

## Provenance

ChildrenOfTasks implements the supplied specification using the Swift Package Factory workflow. Implementation, tests, and repository preparation were performed with coding agents. Separate agent contexts provide review and public-consumer exercises; those checks do not establish human review.

## Author

[Kyle Hughes](https://kylehugh.es)

[![Bluesky](https://img.shields.io/badge/Bluesky-0285FF?logo=bluesky&logoColor=fff)](https://bsky.app/profile/kylehugh.es)<br>
[![LinkedIn](https://img.shields.io/badge/LinkedIn-0A66C2?logo=linkedin&logoColor=fff)](https://www.linkedin.com/in/kyle-hughes)<br>
[![Mastodon](https://img.shields.io/mastodon/follow/109356914477272810?domain=https%3A%2F%2Fmister.computer&style=social)](https://mister.computer/@kyle)
