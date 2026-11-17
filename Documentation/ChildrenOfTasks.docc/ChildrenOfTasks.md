# ``ChildrenOfTasks``

Pass pending results through helpers while one structured scope owns their execution.

## Overview

Start work through the borrowed ``Children`` capability inside ``withChildren(isolation:_:)``. Pass the returned ``Child`` handles to helpers that await ``Child/value()``. Readers receive access to results; the scope owns cancellation and cleanup.

```swift
import ChildrenOfTasks

func loadExport(
    readText: @escaping @Sendable () async -> String,
    readTitle: @escaping @Sendable () async -> String
) async -> String {
    await withChildren { (children: borrowing Children) in
        let text = children.start(readText)
        let title = children.start(readTitle)

        return await render(text, title: title)
    }
}

func render(_ text: Child<String, Never>, title: Child<String, Never>) async -> String {
    let heading = await title.value()
    let content = await text.value()

    return heading + "\n\n" + content
}
```

The application supplies the loading operations. A typed-throwing operation produces a handle with its exact failure type; reading a nonthrowing operation needs no `try`.

When the body returns or throws, the scope requests cancellation of remaining work and waits for all children before delivering the body's original outcome. A caught or ignored child error does not fail the scope. Canceling a reader does not interrupt its wait. Cancellation is cooperative, so an unfinished child can keep the scope open.

The library targets iOS 16.4 and macOS 13 with Swift 6.4. Tests run on newer runtimes; execution on these minimum versions is unverified.

Swift 6.4 has known compiler crashes for inferred invalid captures; spell scope parameters explicitly as borrowed, as shown above.

## Topics

### Starting and observing work

- ``withChildren(isolation:_:)``
- ``Children``
- ``Child``

### Understanding lifetime

- <doc:ScopeLifetime>
