# ChildrenOfTasks

[![Provenance: Software Factory](https://img.shields.io/badge/Provenance-Software_Factory-007AFF)](#provenance)
[![Platform Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2FChildrenOfTasks%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/kylehughes/ChildrenOfTasks)
[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2FChildrenOfTasks%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/kylehughes/ChildrenOfTasks)
[![Test](https://github.com/kylehughes/ChildrenOfTasks/actions/workflows/ci.yml/badge.svg)](https://github.com/kylehughes/ChildrenOfTasks/actions/workflows/ci.yml)

ChildrenOfTasks lets one function start work that other functions can await. Pass the pending results as arguments, return them from helpers, or store them together in a struct. One enclosing `withChildren` scope owns the work and waits for every child to finish before returning.

## Quick start

A profile screen needs a user's profile and recent posts. Its header and feed both use the profile, but only the feed needs the posts. Start both requests together, then let each section's helper read the results it needs.

The app provides `ProfileClient`, `Profile`, and `Post` as `Sendable` types, along with `ProfileScreen` and `PostRow` presentation models. Networking and view code are omitted.

```swift
import ChildrenOfTasks

func loadProfileScreen(userID: String, client: ProfileClient) async throws -> ProfileScreen {
    try await withChildren { (children: borrowing Children) in
        let load = startProfileLoad(userID: userID, client: client, in: children)
        let header = try await makeHeader(from: load.profile)
        let feed = try await makeFeed(from: load)

        return ProfileScreen(header: header, feed: feed)
    }
}
```

The loading helper starts the requests and returns their handles without waiting for either result. `ProfileLoad` groups the two pending values, each with its own result type:

```swift
struct ProfileLoad: Sendable {
    let profile: Child<Profile, any Error>
    let posts: Child<[Post], any Error>
}

func startProfileLoad(
    userID: String,
    client: ProfileClient,
    in children: borrowing Children
) -> ProfileLoad {
    ProfileLoad(
        profile: children.start { try await client.fetchProfile(for: userID) },
        posts: children.start { try await client.fetchPosts(for: userID) }
    )
}
```

The header can be prepared while the posts are still loading. The feed reads the same profile handle, so it gets the same result without making another profile request:

```swift
func makeHeader(from profile: Child<Profile, any Error>) async throws -> String {
    let profile = try await profile.value()

    return profile.displayName
}

func makeFeed(from load: ProfileLoad) async throws -> [PostRow] {
    let profile = try await load.profile.value()
    let posts = try await load.posts.value()

    return posts.map { PostRow(author: profile.displayName, text: $0.text) }
}
```

The requests belong to `loadProfileScreen`'s scope even though another function started them. If building a section throws, the error leaves the scope body, which cancels any remaining work and waits for it to finish before throwing. The helpers pass results around without taking over cleanup.

For sequential work, use direct `await`. For a fixed set of operations started and consumed in one function, `async let` is often enough. A native task group suits processing homogeneous results in completion order. Use an explicitly owned unstructured task when work needs to outlive its caller.

## Installation

The package is available in the private [kylehughes/ChildrenOfTasks](https://github.com/kylehughes/ChildrenOfTasks) repository and has no tagged release. Add a checkout as a local package dependency in Xcode, select the **ChildrenOfTasks** product, and import `ChildrenOfTasks`.

For a neighboring Swift package, replace the path below with the actual checkout path. The explicit dependency name keeps the product reference stable even when the checkout folder has another name:

```swift
.package(name: "ChildrenOfTasks", path: "../ChildrenOfTasks")
```

Add `.product(name: "ChildrenOfTasks", package: "ChildrenOfTasks")` to the consuming target's dependencies.

## Working with handles

`Children` lets a helper add work to the caller's scope. In the example, `startProfileLoad` borrows it for the duration of the call and stores only the returned `Child` handles. Keep `Children` in the creating task: do not store it, capture it in another task, send it to another actor, consume it, or swap it with another scope.

`start` submits an operation to a native task group without waiting for `value()` to be called. Swift controls when it executes; calling `start` does not guarantee that execution has begun before the call returns. Each call to `start` creates a separate operation, even if you supply the same function again.

`Child<Value, Failure>` is copyable and `Sendable`. Pass or store a handle, or share it with concurrent readers. Copies observe the same stored outcome without running the operation again. A handle may outlive its scope, but the operation finishes before `withChildren` returns. Returning a handle from a borrowing helper, as above, lets work continue in the caller's scope; returning it from `withChildren` delivers an already-completed outcome.

The example's client methods use ordinary `throws`, so their handles use `any Error`. If the profile operation instead declares `throws(ProfileError)`, its handle is `Child<Profile, ProfileError>`. If it cannot throw, its handle is `Child<Profile, Never>` and `value()` needs no `try`. Helpers that combine unrelated error types choose their own error vocabulary or use ordinary `throws`.

Child values must be copyable and `Sendable`; reference-valued results retain their normal reference semantics. Return data models from child operations and create or update UI objects on the appropriate actor.

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

Swift 6.4 has known compiler crashes for some forbidden captures when the scope parameter is inferred. Use the explicit `(children: borrowing Children)` spelling shown above. The [compiler fixtures](Tests/CompilerFixtures) retain those failures as known diagnostic defects, separately from expected rejection checks.

## Costs and limits

Each scope creates group storage; each child adds a native task and actor-backed result cell. Suspended readers use continuations, and handles retain completed outcomes. Task-group completion records can accumulate until scope exit, so use a scope for a bounded operation rather than an indefinitely running spawning service.

There is no per-child cancellation, priority API, timeout, retry, stream, or result-combinator family. Waiting on a handle does not promise priority donation from an unrelated reader. No allocation-free or `async let` performance-equivalence claim is made. See [measured costs](Documentation/Performance.md).

## Documentation and maintenance

The [DocC documentation](https://kylehughes.github.io/ChildrenOfTasks/) covers the API. The [scope design](Documentation/ChildrenOfTasks.docc/ScopeLifetime.md) explains borrowing, result publication, and cleanup.

Build and test with Xcode 27.1 selected:

```sh
swift build
swift test
swift format lint --strict --recursive Package.swift Sources Tests Integration Benchmarks
```

[CI](.github/workflows/ci.yml) also checks compiler contracts, a public consumer, DocC, and iOS simulator execution. See [Actions](https://github.com/kylehughes/ChildrenOfTasks/actions) for results and [Maintenance](Documentation/Maintenance.md) for the full verification commands, local documentation preview, and publishing workflow.

The DocC site is published on GitHub Pages. DocC deployments and package releases are manually dispatched; no package release has been published.

## Contributions

ChildrenOfTasks is not accepting source contributions at this time. Bug reports will be considered.

## Provenance

ChildrenOfTasks implements the supplied specification using the Swift Package Factory workflow. Implementation, tests, and repository preparation were performed with coding agents. Separate agent contexts provide review and public-consumer exercises; those checks do not establish human review.

## Author

[Kyle Hughes](https://kylehugh.es)

[![Bluesky](https://img.shields.io/badge/Bluesky-0285FF?logo=bluesky&logoColor=fff)](https://bsky.app/profile/kylehugh.es)<br>
[![LinkedIn](https://img.shields.io/badge/LinkedIn-0A66C2?logo=linkedin&logoColor=fff)](https://www.linkedin.com/in/kyle-hughes)<br>
[![Mastodon](https://img.shields.io/mastodon/follow/109356914477272810?domain=https%3A%2F%2Fmister.computer&style=social)](https://mister.computer/@kyle)
