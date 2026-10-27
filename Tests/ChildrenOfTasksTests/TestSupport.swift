import ChildrenOfTasks
import Foundation
import Testing

/// A retained one-shot event. Its deadline bounds broken tests; it never supplies readiness.
actor TestEvent {
    private var signaled = false
    private var nextID = 0
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    var isSignaled: Bool {
        signaled
    }

    func signal() {
        signaled = true
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(returning: true)
        }
    }

    func wait() async -> Bool {
        if signaled {
            return true
        }
        let id = nextID
        nextID += 1
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            expire(id)
        }
        let observed = await withCheckedContinuation { continuation in
            waiters[id] = continuation
        }
        deadline.cancel()
        await deadline.value

        return observed
    }

    private func expire(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(returning: false)
    }
}

actor InvocationCounter {
    private(set) var count = 0

    func increment() -> Int {
        count += 1
        return count
    }
}

enum FirstFailure: Error, Equatable {
    case rejected(Int)
}
enum SecondFailure: Error, Equatable {
    case stopped
}

struct Payload: Sendable, Equatable {
    let number: Int
}

final class ReferencePayload: Sendable {
    let number: Int
    init(_ number: Int) {
        self.number = number
    }
}

func forwarding<Value, Failure>(
    _ children: borrowing Children,
    operation: @escaping @Sendable () async throws(Failure) -> Value
) -> Child<Value, Failure> where Value: Sendable, Failure: Error {
    children.start(operation)
}

func read<Value, Failure>(_ child: Child<Value, Failure>) async throws(Failure) -> Value
where Value: Sendable, Failure: Error {
    try await child.value()
}

enum TestContext {
    @TaskLocal static var label = "outside"
}
