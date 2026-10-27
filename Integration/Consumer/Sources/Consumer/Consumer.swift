import ChildrenOfTasks

nonisolated enum FirstFailure: Error {
    case first
}
nonisolated enum SecondFailure: Error {
    case second
}
nonisolated struct Payload: Sendable, Equatable {
    let value: Int
}
nonisolated final class SharedValue: Sendable {
    let value = 9
}
nonisolated final class LocalValue {
    var value = 1
}

nonisolated func prepare<Value, Failure>(
    _ operation: @escaping @Sendable () async throws(Failure) -> Value,
    in children: borrowing Children
) -> Child<Value, Failure> where Value: Sendable, Failure: Error {
    children.start(operation)
}

nonisolated func forward<Value, Failure>(
    _ operation: @escaping @Sendable () async throws(Failure) -> Value
) async throws(Failure) -> Value where Value: Sendable, Failure: Error {
    try await withChildren { (children: borrowing Children) throws(Failure) in
        try await prepare(operation, in: children).value()
    }
}

nonisolated func first() async throws(FirstFailure) -> Int {
    throw .first
}
nonisolated func second() async throws(SecondFailure) -> String {
    throw .second
}
nonisolated func untyped() async throws -> Int {
    throw FirstFailure.first
}

actor Counter {
    private var count = 0

    func exercise() async -> Int {
        await withChildren { (children: borrowing Children) in
            count += 1
            let child = children.start {
                await self.read()
            }

            return await child.value()
        }
    }

    func read() -> Int {
        count
    }
}

@MainActor func mainActorBody() async -> LocalValue {
    let local = LocalValue()

    return await withChildren { (children: borrowing Children) in
        local.value += 1
        let child = children.start { @MainActor in
            MainActor.assertIsolated()

            return local.value
        }

        let result = await child.value()
        precondition(result == 2)

        return local
    }
}

@main struct Consumer {
    @MainActor static func main() async {
        let payload = await forward {
            Payload(value: 7)
        }

        precondition(payload == Payload(value: 7))
        let optional: Int? = await forward {
            nil as Int?
        }

        precondition(optional == nil)
        let reference = await forward {
            SharedValue()
        }

        precondition(reference.value == 9)
        let _: Void = await forward {
        }

        do {
            _ = try await forward(untyped)
            preconditionFailure("Expected untyped failure")
        } catch {
            precondition(error is FirstFailure)
        }

        await withChildren { (children: borrowing Children) in
            let a: Child<Int, FirstFailure> = prepare(first, in: children)
            let b: Child<String, SecondFailure> = prepare(second, in: children)
            do throws(FirstFailure) {
                _ = try await a.value()
                preconditionFailure("Expected first")
            } catch {
                precondition(error == .first)
            }

            do throws(SecondFailure) {
                _ = try await b.value()
                preconditionFailure("Expected second")
            } catch {
                precondition(error == .second)
            }
        }

        let local = await mainActorBody()
        let localValue = local.value
        precondition(localValue == 2)
        let count = await Counter().exercise()
        precondition(count == 1)
        print("Public consumer passed")
    }
}
