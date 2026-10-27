/// Serializes reader registration and the single publication of an outcome.
actor ChildResult<Value, Failure> where Value: Sendable, Failure: Error {
    private var state = State.pending([])

    func publish(_ result: Result<Value, Failure>) {
        guard case .pending(let waiters) = state else {
            preconditionFailure("A child operation must publish exactly once.")
        }

        state = .resolved(result)

        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    func read() async -> Result<Value, Failure> {
        if case .resolved(let result) = state {
            return result
        }

        return await withCheckedContinuation {
            register($0)
        }
    }

    func register(_ waiter: CheckedContinuation<Result<Value, Failure>, Never>) {
        switch state {
        case .pending(var waiters):
            // Move the array out before appending to avoid copying all existing
            // waiters merely because the enum still retains its old payload.
            state = .pending([])
            waiters.append(waiter)
            state = .pending(waiters)
        case .resolved(let result):
            waiter.resume(returning: result)
        }
    }
}

extension ChildResult {
    private enum State {
        case pending([CheckedContinuation<Result<Value, Failure>, Never>])
        case resolved(Result<Value, Failure>)
    }
}
