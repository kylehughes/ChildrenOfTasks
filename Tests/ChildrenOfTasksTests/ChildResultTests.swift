import Testing

@testable import ChildrenOfTasks

@Suite(.timeLimit(.minutes(1)))
struct ChildResultTests {
    @Test(arguments: [false, true])
    func registeredReadersAllReceiveOneStoredOutcome(fails: Bool) async {
        let cell = ChildResult<Int, FirstFailure>()
        let attachments = (0 ..< 16)
            .map {
                _ in TestEvent()
            }
        let expected: Result<Int, FirstFailure> = fails ? .failure(.rejected(61)) : .success(61)
        await withTaskGroup(of: Result<Int, FirstFailure>.self) { readers in
            for attached in attachments {
                readers.addTask {
                    await cell.read(signaling: attached)
                }
            }
            for attached in attachments {
                #expect(await attached.wait())
            }
            // Each signal occurs after production register() returned, before publication.
            await cell.publish(expected)
            for await outcome in readers {
                #expect(outcome == expected)
            }
        }
        #expect(await cell.read() == expected)
    }

    @Test(arguments: [false, true])
    func cancelingAnAttachedReaderDoesNotChangeItsOutcome(fails: Bool) async {
        let cell = ChildResult<Int, FirstFailure>()
        let attached = TestEvent()
        let expected: Result<Int, FirstFailure> = fails ? .failure(.rejected(67)) : .success(67)
        let reader = Task {
            let outcome = await cell.read(signaling: attached)
            #expect(Task.isCancelled)
            return outcome
        }
        #expect(await attached.wait())
        reader.cancel()
        await cell.publish(expected)
        #expect(await reader.value == expected)
    }
}

extension ChildResult {
    /// Uses the exact registration path called by read(), then reports attachment from the test target.
    fileprivate func read(signaling attached: TestEvent) async -> Result<Value, Failure> {
        await withCheckedContinuation { continuation in
            register(continuation)
            Task {
                await attached.signal()
            }
        }
    }
}
