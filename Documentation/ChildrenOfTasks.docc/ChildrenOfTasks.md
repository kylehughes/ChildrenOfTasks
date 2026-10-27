# ``ChildrenOfTasks``

Pass pending results through helpers while one structured scope owns their execution.

## Overview

Open a scope with ``withChildren(isolation:_:)``, start operations through the borrowed ``Children`` capability, and observe typed outcomes through ``Child/value()``. Handles may be shared or returned. All producers finish before the enclosing scope returns.

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

The application supplies the loading operations. A typed-throwing operation produces a handle with its exact failure type; observing a nonthrowing operation needs no `try`.

On body return or error, the scope requests cancellation and waits for all children before delivering the body's original outcome. Ignoring a child error does not fail the scope. Canceling a reader does not interrupt its wait. Cancellation is cooperative, so an unfinished child can keep the scope open.

The library targets iOS 16.4 and macOS 13 with Swift 6.4. Actual iOS 16.4 runtime validation remains required before release acceptance. The tested compiler has known diagnostic crashes for inferred invalid captures; spell scope parameters explicitly as borrowed, as shown above.

## Topics

### Starting and observing work

- ``withChildren(isolation:_:)``
- ``Children``
- ``Child``

### Understanding lifetime

- <doc:ScopeLifetime>
