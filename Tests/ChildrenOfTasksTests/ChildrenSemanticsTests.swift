import ChildrenOfTasks
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ChildrenSemanticsTests {
    @Test func transportsExactValuesAndFailures() async {
        await withChildren { (children: borrowing Children) in
            let scalar: Child<Int, Never> = forwarding(children) {
                42
            }
            let structure: Child<Payload, Never> = children.start {
                Payload(number: 7)
            }
            let optional: Child<Int?, Never> = children.start {
                nil
            }
            let reference = ReferencePayload(9)
            let object: Child<ReferencePayload, Never> = children.start {
                reference
            }
            let nothing: Child<Void, Never> = children.start {

            }
            let failure: Child<Int, FirstFailure> = children.start { () throws(FirstFailure) in
                throw .rejected(3)
            }
            let unrelated: Child<String, SecondFailure> = children.start { () throws(SecondFailure) in
                throw .stopped
            }
            let erased: Child<Int, any Error> = children.start { () throws in
                throw FirstFailure.rejected(8)
            }
            #expect(await read(scalar) == 42)
            #expect(await structure.value() == Payload(number: 7))
            #expect(await optional.value() == nil)
            #expect(await object.value() === reference)
            await nothing.value()
            await #expect(throws: FirstFailure.rejected(3)) {
                try await failure.value()
            }
            await #expect(throws: SecondFailure.stopped) {
                try await unrelated.value()
            }
            await #expect(throws: FirstFailure.rejected(8)) {
                try await erased.value()
            }
        }
    }

    @Test func equivalentStartsExecuteIndependentlyAndReadsDoNotRerun() async {
        let counter = InvocationCounter()
        await withChildren { (children: borrowing Children) in
            let operation: @Sendable () async -> Int = {
                await counter.increment()
            }
            let first = children.start(operation)
            let second = children.start(operation)
            let firstValue = await first.value()
            let secondValue = await second.value()
            #expect(Set([firstValue, secondValue]) == Set([1, 2]))
            #expect(await first.value() == firstValue)
            #expect(await second.value() == secondValue)
        }
        #expect(await counter.count == 2)
    }

    @Test(arguments: [false, true])
    func exitCancelsAndJoinsIgnoredChild(throwBody: Bool) async {
        let entered = TestEvent()
        let canceled = TestEvent()
        let cleaned = TestEvent()
        do {
            let result = try await withChildren { (children: borrowing Children) throws(SecondFailure) in
                _ = children.start {
                    await withTaskCancellationHandler {
                        await entered.signal()
                        #expect(await canceled.wait())
                        await cleaned.signal()

                    } onCancel: {

                        Task {
                            await canceled.signal()
                        }
                    }
                }
                #expect(await entered.wait())
                if throwBody {
                    throw .stopped
                }
                return 17
            }
            #expect(!throwBody)
            #expect(result == 17)

        } catch {

            #expect(throwBody)
            #expect(error == .stopped)
        }
        #expect(await cleaned.isSignaled)
    }

    @Test func returnedHandleIsCompletedAndReadableAfterScope() async {
        let completed = TestEvent()
        let handle = await withChildren { (children: borrowing Children) in
            children.start {
                await completed.signal()
                return 23
            }
        }
        #expect(await completed.isSignaled)
        #expect(await handle.value() == 23)
        #expect(await handle.value() == 23)
    }

    @Test func ignoredAndCaughtFailuresDoNotCancelSiblingOrReplaceBodyOutcome() async {
        let allowSibling = TestEvent()
        await withChildren { (children: borrowing Children) in
            _ = children.start {
                () throws(FirstFailure) -> Int in throw .rejected(1)
            }
            let sibling = children.start {
                #expect(await allowSibling.wait())
                #expect(!Task.isCancelled)
                return 29
            }
            let caught = children.start {
                () throws(SecondFailure) -> Int in throw .stopped
            }
            await #expect(throws: SecondFailure.stopped) {
                try await caught.value()
            }
            await allowSibling.signal()
            #expect(await sibling.value() == 29)
        }
        await #expect(throws: SecondFailure.stopped) {
            try await withChildren { (children: borrowing Children) throws(SecondFailure) in
                _ = children.start {
                    () throws(FirstFailure) -> Int in throw .rejected(2)
                }
                throw .stopped
            }
        }
    }

    @Test func propagatedChildFailureBecomesBodyFailure() async {
        await #expect(throws: FirstFailure.rejected(71)) {
            try await withChildren { (children: borrowing Children) throws(FirstFailure) in
                let child = children.start {
                    () throws(FirstFailure) -> Int in throw .rejected(71)
                }
                return try await child.value()
            }
        }
    }

    @Test func bodyErrorWinsOverChildFailureDuringDrain() async {
        let entered = TestEvent()
        let canceled = TestEvent()
        let finished = TestEvent()
        await #expect(throws: SecondFailure.stopped) {
            try await withChildren { (children: borrowing Children) throws(SecondFailure) in
                _ = children.start { () async throws(FirstFailure) -> Int in
                    await withTaskCancellationHandler {
                        await entered.signal()
                        #expect(await canceled.wait())

                    } onCancel: {

                        Task {
                            await canceled.signal()
                        }
                    }
                    await finished.signal()
                    throw .rejected(73)
                }
                #expect(await entered.wait())
                throw .stopped
            }
        }
        #expect(await finished.isSignaled)
    }

    @Test(arguments: [false, true])
    func creationRunsEvenWhenAlreadyCanceled(cancelBeforeEntry: Bool) async {
        let ready = TestEvent()
        let proceed = TestEvent()
        let parent = Task {
            if cancelBeforeEntry {
                await ready.signal()
                #expect(await proceed.wait())
            }
            return await withChildren { (children: borrowing Children) in
                if !cancelBeforeEntry {
                    let first = children.start {
                        1
                    }
                    #expect(await first.value() == 1)
                    await ready.signal()
                    #expect(await proceed.wait())
                }
                let child: Child<Bool, Never> = children.start {
                    Task.isCancelled
                }
                let typed: Child<Int, FirstFailure> = children.start { () throws(FirstFailure) in
                    #expect(Task.isCancelled)
                    throw .rejected(5)
                }
                await #expect(throws: FirstFailure.rejected(5)) {
                    try await typed.value()
                }
                return await child.value()
            }
        }
        #expect(await ready.wait())
        parent.cancel()
        await proceed.signal()
        #expect(await parent.value)
    }

    @Test func parentCancellationReachesChildAndJoinsCleanup() async {
        let entered = TestEvent()
        let canceled = TestEvent()
        let cleaned = TestEvent()
        let parent = Task {
            await withChildren { (children: borrowing Children) in
                let child = children.start {
                    await withTaskCancellationHandler {
                        await entered.signal()
                        #expect(await canceled.wait())
                        #expect(Task.isCancelled)
                        await cleaned.signal()
                        return 31

                    } onCancel: {

                        Task {
                            await canceled.signal()
                        }
                    }
                }
                return await child.value()
            }
        }
        #expect(await entered.wait())
        parent.cancel()
        #expect(await parent.value == 31)
        #expect(await cleaned.isSignaled)
    }

    @Test func noncooperativeChildAndDroppedHandleRemainOwnedUntilReleased() async {
        let entered = TestEvent()
        let canceled = TestEvent()
        let release = TestEvent()
        let finished = TestEvent()
        let parent = Task {
            let result = await withChildren { (children: borrowing Children) in
                _ = children.start {
                    await withTaskCancellationHandler {
                        await entered.signal()
                        #expect(await release.wait())
                        #expect(Task.isCancelled)
                        await finished.signal()

                    } onCancel: {

                        Task {
                            await canceled.signal()
                        }
                    }
                }
                #expect(await entered.wait())
                return 37
            }

            #expect(await finished.isSignaled)

            return result
        }
        // Cancellation is delivered during teardown while the ignored producer is still gated.
        #expect(await canceled.wait())
        await release.signal()
        #expect(await parent.value == 37)
        #expect(await finished.isSignaled)
    }

    @Test func emptyNestedAndChildOwnedScopesCompose() async {
        #expect(
            await withChildren {
                (_: borrowing Children) in 3
            } == 3
        )
        let result = await withChildren { (outer: borrowing Children) in
            let first = forwarding(outer) {
                5
            }
            let nested = await withChildren { (inner: borrowing Children) in
                await inner.start {
                    7
                }
                .value()
            }
            let ownScope = outer.start {
                await withChildren {
                    (inner: borrowing Children) in
                    await inner.start {
                        11
                    }
                    .value()
                }
            }
            return await first.value() + nested + ownScope.value()
        }
        #expect(result == 23)
    }

    @Test func childInheritsTaskLocalContext() async {
        let result = await TestContext.$label.withValue("parent") {
            await withChildren { (children: borrowing Children) in
                await children.start {
                    TestContext.label
                }
                .value()
            }
        }
        #expect(result == "parent")
        #expect(TestContext.label == "outside")
    }
}
