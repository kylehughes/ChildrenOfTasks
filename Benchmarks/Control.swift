// Benchmark-local control copied from Specification/Experiments/Core/Children.swift.
// This archived native group plus typed actor-cell implementation is not production code.
private actor Cell<Value: Sendable, Failure: Error> {
    var result: Result<Value, Failure>?
    var waiters: [CheckedContinuation<Result<Value, Failure>, Never>] = []

    func publish(_ result: Result<Value, Failure>) {
        precondition(self.result == nil)
        self.result = result
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: result)
        }
    }

    func read() async -> Result<Value, Failure> {
        if let result {
            return result
        }

        return await withCheckedContinuation {
            waiters.append($0)
        }
    }
}

/// The archived probe's typed result handle, renamed only to avoid import collisions.
public struct ControlChild<Value: Sendable, Failure: Error>: Sendable {
    private let cell: Cell<Value, Failure>
    fileprivate init(_ cell: Cell<Value, Failure>) {
        self.cell = cell
    }

    /// Reads the immutable outcome using the archived actor cell.
    public func value() async throws(Failure) -> Value {
        try await cell.read().get()
    }
}

private final class GroupStorage {
    var group: TaskGroup<Void>
    init(_ group: TaskGroup<Void>) {
        self.group = group
    }
}

/// The archived probe's borrowed native-group authority.
public struct ControlChildren: ~Copyable {
    private let storage: GroupStorage
    fileprivate init(_ group: TaskGroup<Void>) {
        storage = GroupStorage(group)
    }

    /// Starts exactly one structured operation using the archived implementation.
    public borrowing func start<Value: Sendable, Failure: Error>(
        _ operation: @escaping @Sendable () async throws(Failure) -> Value
    ) -> ControlChild<Value, Failure> {
        let cell = Cell<Value, Failure>()
        storage.group.addTask {
            let result: Result<Value, Failure>
            do throws(Failure) {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }

            await cell.publish(result)
        }

        return ControlChild(cell)
    }

    fileprivate borrowing func cancelAll() {
        storage.group.cancelAll()
    }
}

/// Runs the archived scope, canceling and joining on body exit.
public func withControlChildren<Value, Failure: Error>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (borrowing ControlChildren) async throws(Failure) -> Value
) async throws(Failure) -> Value {
    let result: Result<Value, Failure> = await withTaskGroup(
        of: Void.self,
        returning: Result<Value, Failure>.self,
        isolation: isolation
    ) {
        group in
        let children = ControlChildren(group)
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
