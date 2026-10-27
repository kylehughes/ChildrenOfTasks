/// A shareable handle to the outcome of one structured child operation.
///
/// Pass handles to helpers or share them across tasks while the enclosing
/// ``withChildren(isolation:_:)`` scope owns their producers. A handle can outlive
/// its scope, but its producer finishes before that scope returns.
///
/// Copies share one stored outcome. Retaining a handle retains that outcome;
/// dropping a handle does not cancel its producer. Reference-valued results keep
/// their ordinary reference semantics rather than becoming deep snapshots.
public struct Child<Value, Failure>: Sendable where Value: Sendable, Failure: Error {
    private let result: ChildResult<Value, Failure>

    fileprivate init(_ result: ChildResult<Value, Failure>) {
        self.result = result
    }

    /// Waits for the operation's stored outcome.
    ///
    /// Repeated and concurrent reads return the same outcome without running the
    /// operation again. A canceled reader keeps waiting; cancellation neither
    /// interrupts this wait nor introduces an error into the failure type.
    ///
    /// Publication means the supplied operation has returned or thrown. The
    /// wrapping child task may still be returning from publication; only scope
    /// exit establishes that all child tasks have been joined.
    ///
    /// - Returns: The value produced by the operation.
    /// - Throws: The operation's exact failure. Nonthrowing operations produce a
    ///   `Child<Value, Never>` whose `value()` call needs no `try`.
    public func value() async throws(Failure) -> Value {
        try await result.read().get()
    }
}

/// Borrowed authority to start work in one structured scope.
///
/// Obtain this value through ``withChildren(isolation:_:)`` and use it only in
/// the creating task, including through borrowing helpers. It cannot be copied,
/// consumed, swapped with another scope, stored beyond the borrow, or captured
/// by child work. A child can open its own independent scope.
///
/// Keep scopes bounded: completed native task-group records can accumulate until
/// scope exit. This type is deliberately noncopyable and non-Sendable.
public struct Children: ~Copyable {
    private let storage: GroupStorage

    fileprivate init(_ group: TaskGroup<Void>) {
        storage = GroupStorage(group)
    }

    /// Starts one structured child and returns its typed result handle.
    ///
    /// Each call submits an independent execution, even if cancellation has
    /// already been requested. The operation observes native task cancellation
    /// and decides how to respond; successful results are never replaced by a
    /// cancellation error. Scheduling order is unspecified.
    ///
    /// Child failures are stored for observation through the handle. An ignored
    /// or caught child failure does not fail the scope or cancel siblings.
    /// Explicit actor-isolated operations retain their isolation. Arbitrary
    /// closure literals are not promised to inherit the caller's actor context.
    ///
    /// - Parameter operation: An escaping, Sendable operation with a copyable,
    ///   Sendable result and its own failure type.
    /// - Returns: A handle that can be shared independently of this authority.
    public borrowing func start<Value, Failure>(
        _ operation: @escaping @Sendable () async throws(Failure) -> Value
    ) -> Child<Value, Failure> where Value: Sendable, Failure: Error {
        let result = ChildResult<Value, Failure>()
        storage.group.addTask {
            let outcome: Result<Value, Failure>

            do throws(Failure) {
                outcome = .success(try await operation())
            } catch {
                outcome = .failure(error)
            }

            await result.publish(outcome)
        }

        return Child(result)
    }

    fileprivate borrowing func cancelAll() {
        storage.group.cancelAll()
    }
}

/// Runs a body whose child operations finish before the call returns.
///
/// On every ordinary return or thrown error from `body`, the scope requests
/// cancellation of remaining work, joins all children, then delivers the body's
/// original outcome. Ignored child errors cannot replace it. Returning a handle
/// from the body therefore delivers an already-completed outcome to the caller.
///
/// Parent cancellation reaches children through native structured concurrency.
/// Cancellation is cooperative: it does not force the body or children to return.
/// A child that never finishes can prevent this call from returning indefinitely.
///
/// The body inherits the caller's actor isolation and can return actor-local,
/// non-Sendable state. Each child operation still crosses a task boundary.
///
/// - Parameters:
///   - isolation: The actor isolation of the scope body, inherited from the caller.
///   - body: A body borrowing spawning authority. Spell the parameter as
///     `(children: borrowing Children)` in ownership-sensitive code to avoid
///     known Swift 6.4 diagnostics crashes for inferred invalid captures.
/// - Returns: The body's result after all children have finished.
/// - Throws: The body's exact error after all children have finished.
public func withChildren<Value, Failure>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (borrowing Children) async throws(Failure) -> Value
) async throws(Failure) -> Value where Failure: Error {
    let result: Result<Value, Failure> = await withTaskGroup(
        of: Void.self,
        returning: Result<Value, Failure>.self,
        isolation: isolation
    ) { group in
        // The storage copy is used only in this creating task and group body.
        // Do not separately mutate `group` while the borrowed authority is active.
        let children = Children(group)
        defer {
            children.cancelAll()
        }

        do throws(Failure) {
            return .success(try await body(children))
        } catch {
            return .failure(error)
        }
    }

    return try result.get()
}

// This storage must stay private and non-Sendable. Neither handles nor child
// closures retain it; only the borrowed capability accesses the scoped group.
private final class GroupStorage {
    var group: TaskGroup<Void>

    init(_ group: TaskGroup<Void>) {
        self.group = group
    }
}
