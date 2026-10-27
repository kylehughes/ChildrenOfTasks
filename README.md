# ChildrenOfTasks

[![Provenance: Software Factory](https://img.shields.io/badge/Provenance-Software_Factory-007AFF)](#provenance)
[![Platform Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2FChildrenOfTasks%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/kylehughes/ChildrenOfTasks)
[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fkylehughes%2FChildrenOfTasks%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/kylehughes/ChildrenOfTasks)
[![Test](https://github.com/kylehughes/ChildrenOfTasks/actions/workflows/ci.yml/badge.svg)](https://github.com/kylehughes/ChildrenOfTasks/actions/workflows/ci.yml)

ChildrenOfTasks lets helpers return unfinished work while one enclosing scope handles cancellation and cleanup. Pass typed `Child` handles between functions; every child finishes before `withChildren` returns.

`Task` handles also let you pass pending results between functions. Tasks created with `Task { … }` are unstructured, though: keeping them within the caller's lifetime requires explicit cancellation forwarding and a cleanup path that cancels and awaits every task on exit. `withChildren` takes care of those responsibilities for native child tasks, including when its body throws.

## Quick start

A profile screen needs a user's profile for its header and recent posts for its feed. A loading helper starts both requests, and separate presentation helpers await the data they need. If the profile request fails, `loadProfileScreen` still needs to cancel and wait for the posts request before throwing.

The app provides `ProfileClient`, `Profile`, and `Post` as `Sendable` types, along with `ProfileScreen` and `PostRow` presentation models. Networking and view code are omitted.

```swift
import ChildrenOfTasks

func loadProfileScreen(userID: String, client: ProfileClient) async throws -> ProfileScreen {
    try await withChildren { (children: borrowing Children) in
        let load = startProfileLoad(userID: userID, client: client, in: children)
        let header = try await makeHeader(from: load.profile)
        let feed = try await makeFeed(from: load.posts)

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

The header can be prepared while posts are still loading. Neither presentation helper needs the client or responsibility for ending the requests:

```swift
func makeHeader(from profile: Child<Profile, any Error>) async throws -> String {
    let profile = try await profile.value()

    return profile.displayName
}

func makeFeed(from posts: Child<[Post], any Error>) async throws -> [PostRow] {
    let posts = try await posts.value()

    return posts.map { PostRow(text: $0.text) }
}
```

`makeHeader` and `makeFeed` receive access to results, with no authority to cancel the requests. If either helper throws, `withChildren` cancels remaining work, waits for it to finish, then throws that error. The caller does not need a separate cleanup path for each request.

### Using native Swift

When a fixed set of operations starts and finishes in one function, `async let` already provides structured lifetime management. Use it when the work can stay local. A native task group is useful for a dynamic set of operations, including processing results of one type in completion order.

The same profile-loading flow can use `Task` handles, with cancellation forwarding and exit cleanup written explicitly. Each new task needs to be included in both paths.

<details>
<summary>The same profile-loading flow with Task handles</summary>

This version uses asynchronous `defer`, available in Swift 6.4. The app-provided types are the same as above.

```swift
func loadProfileScreen(userID: String, client: ProfileClient) async throws -> ProfileScreen {
    let load = startProfileLoad(userID: userID, client: client)

    return try await withTaskCancellationHandler {
        defer {
            load.profile.cancel()
            load.posts.cancel()
            _ = await load.profile.result
            _ = await load.posts.result
        }

        let header = try await makeHeader(from: load.profile)
        let feed = try await makeFeed(from: load.posts)

        return ProfileScreen(header: header, feed: feed)
    } onCancel: {
        load.profile.cancel()
        load.posts.cancel()
    }
}

struct ProfileLoad: Sendable {
    let profile: Task<Profile, any Error>
    let posts: Task<[Post], any Error>
}

func startProfileLoad(userID: String, client: ProfileClient) -> ProfileLoad {
    ProfileLoad(
        profile: Task { try await client.fetchProfile(for: userID) },
        posts: Task { try await client.fetchPosts(for: userID) }
    )
}

func makeHeader(from profile: Task<Profile, any Error>) async throws -> String {
    let profile = try await profile.value

    return profile.displayName
}

func makeFeed(from posts: Task<[Post], any Error>) async throws -> [PostRow] {
    let posts = try await posts.value

    return posts.map { PostRow(text: $0.text) }
}
```

The cancellation handler forwards cancellation while the body is running. The `defer` requests cancellation on every exit and waits for both tasks. Awaiting their nonthrowing `result` properties ensures a cleanup error cannot skip the other task or replace the body's outcome.

</details>

Both versions rely on cooperative cancellation: an operation that ignores cancellation must still finish before the enclosing call can return.

## Installation

In Xcode, add `https://github.com/kylehughes/ChildrenOfTasks` with the **Branch** dependency rule set to `main`, then select the **ChildrenOfTasks** product.

In `Package.swift`, add the dependency:

```swift
.package(url: "https://github.com/kylehughes/ChildrenOfTasks.git", branch: "main")
```

Add `.product(name: "ChildrenOfTasks", package: "ChildrenOfTasks")` to the consuming target's dependencies, then `import ChildrenOfTasks`. The package has no external dependencies.

### Compatibility

- Requires Swift 6.4 or later. The package uses Swift 6 language mode and complete strict concurrency checking.
- Declares deployment targets of iOS 16.4 and macOS 13. See [runtime validation](Documentation/Maintenance.md#runtime-validation) for the environments exercised.
- Uses nonisolated default actor isolation without upcoming or experimental feature flags. It can be consumed by apps that use MainActor default isolation.

Swift 6.4 has known compiler crashes for some forbidden captures when the scope parameter is inferred. Use the explicit `(children: borrowing Children)` spelling shown above. The [compiler fixtures](Tests/CompilerFixtures) retain those failures as known diagnostic defects, separately from expected rejection checks.

## Usage

### Working with handles

`Children` lets a helper add work to the caller's scope. In the example, `startProfileLoad` borrows it for the duration of the call and stores only the returned `Child` handles. Keep `Children` in the creating task: do not store it, capture it in another task, send it to another actor, consume it, or swap it with another scope.

`start` submits an operation to a native task group without waiting for `value()` to be called. Swift controls when it executes; calling `start` does not guarantee that execution has begun before the call returns. Each call to `start` creates a separate operation, even if you supply the same function again.

`Child<Value, Failure>` is copyable and `Sendable`. Pass or store a handle, or share it with concurrent readers. Copies observe the same stored outcome without running the operation again. A handle may outlive its scope, but the operation finishes before `withChildren` returns. Returning a handle from a borrowing helper, as above, lets work continue in the caller's scope; returning it from `withChildren` delivers an already-completed outcome.

The example's client methods use ordinary `throws`, so their handles use `any Error`. If the profile operation instead declares `throws(ProfileError)`, its handle is `Child<Profile, ProfileError>`. If it cannot throw, its handle is `Child<Profile, Never>` and `value()` needs no `try`. Helpers that combine unrelated error types choose their own error vocabulary or use ordinary `throws`.

### Completion and cancellation

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

### Actor isolation

Child values must be copyable and `Sendable`; reference-valued results retain their normal reference semantics. Return data models from child operations and create or update UI objects on the appropriate actor.

The body inherits the caller's actor isolation and may return actor-local, non-Sendable state. Child operations cross a task boundary and accept escaping `@Sendable` closures. Explicit actor-isolated operations retain their isolation; arbitrary child closure literals are not promised to inherit the caller's actor context.

### Costs and limits

Each scope creates group storage; each child adds a native task and actor-backed result cell. Suspended readers use continuations, and handles retain completed outcomes. Task-group completion records can accumulate until scope exit, so use a scope for a bounded operation rather than an indefinitely running spawning service.

The API covers starting children and reading their results. It does not include per-child cancellation, priorities, timeouts, retries, streams, or result combinators. Waiting on a handle does not promise priority donation from an unrelated reader. See [measured costs](Documentation/Performance.md) for allocation and timing observations.

## Documentation and maintenance

The [DocC documentation](https://kylehughes.github.io/ChildrenOfTasks/) covers the API. The [scope design](Documentation/ChildrenOfTasks.docc/ScopeLifetime.md) explains borrowing, result publication, and cleanup.

### Building and testing

Build and test with Xcode 27.1 selected:

```sh
swift build
swift test
swift format lint --strict --recursive Package.swift Sources Tests Integration Benchmarks
```

[CI](.github/workflows/ci.yml) also checks compiler contracts, a public consumer, DocC, and iOS simulator execution. See [Actions](https://github.com/kylehughes/ChildrenOfTasks/actions) for results and [Maintenance](Documentation/Maintenance.md) for the full verification commands, local documentation preview, and publishing workflow.

## Contributions

ChildrenOfTasks is not accepting source contributions at this time. Bug reports will be considered.

## Provenance

ChildrenOfTasks was developed and reviewed with coding agents using the Swift Package Factory workflow.

## Author

[Kyle Hughes](https://kylehugh.es)

[![Bluesky](https://img.shields.io/badge/Bluesky-0285FF?logo=bluesky&logoColor=fff)](https://bsky.app/profile/kylehugh.es)<br>
[![LinkedIn](https://img.shields.io/badge/LinkedIn-0A66C2?logo=linkedin&logoColor=fff)](https://www.linkedin.com/in/kyle-hughes)<br>
[![Mastodon](https://img.shields.io/mastodon/follow/109356914477272810?domain=https%3A%2F%2Fmister.computer&style=social)](https://mister.computer/@kyle)
