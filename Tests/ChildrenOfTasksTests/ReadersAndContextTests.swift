import ChildrenOfTasks
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ReadersAndContextTests {
    @Test(arguments: [false, true])
    func concurrentReadersRacePublicationAndReadStoredOutcome(fails: Bool) async {
        let release = TestEvent()
        let producerReady = TestEvent()
        await withChildren { (children: borrowing Children) in
            let child: Child<Int, FirstFailure> = children.start { () async throws(FirstFailure) in
                await producerReady.signal()
                #expect(await release.wait())
                if fails {
                    throw .rejected(41)
                }

                return 41
            }

            #expect(await producerReady.wait())
            await withTaskGroup(of: Void.self) { readers in
                for _ in 0 ..< 24 {
                    readers.addTask {
                        if fails {
                            await #expect(throws: FirstFailure.rejected(41)) {
                                try await child.value()
                            }

                        } else {

                            #expect((try? await child.value()) == 41)
                        }
                    }
                }

                await release.signal()
            }

            // The completed first wave proves publication before this second wave starts.
            await withTaskGroup(of: Void.self) { readers in
                for _ in 0 ..< 8 {
                    readers.addTask {
                        if fails {
                            await #expect(throws: FirstFailure.rejected(41)) {
                                try await child.value()
                            }

                        } else {

                            #expect((try? await child.value()) == 41)
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func canceledUnrelatedReaderStillReceivesPublishedOutcome(fails: Bool) async {
        let release = TestEvent()
        let producerReady = TestEvent()
        let readerReady = TestEvent()
        await withChildren { (children: borrowing Children) in
            let child: Child<Int, FirstFailure> = children.start { () async throws(FirstFailure) in
                await producerReady.signal()
                #expect(await release.wait())
                #expect(!Task.isCancelled)
                if fails {
                    throw .rejected(43)
                }

                return 43
            }

            #expect(await producerReady.wait())
            let reader = Task {
                await readerReady.signal()
                do throws(FirstFailure) {
                    let value = try await child.value()
                    #expect(!fails)
                    #expect(value == 43)

                } catch {

                    #expect(fails)
                    #expect(error == .rejected(43))
                }

                #expect(Task.isCancelled)
            }

            #expect(await readerReady.wait())
            reader.cancel()
            await release.signal()
            await reader.value
        }
    }

    @MainActor
    @Test func mainActorBodyCanReturnLocalNonSendableState() async {
        let state = LocalState()
        let returned = await withChildren { (children: borrowing Children) in
            state.number += 1
            let child = children.start { @MainActor in
                MainActor.assertIsolated()

                return 47
            }

            state.number += await child.value()

            return state
        }

        #expect(returned === state)
        #expect(returned.number == 48)
    }

    @Test func customActorBodyPreservesItsIsolation() async {
        let owner = ContextOwner()
        #expect(await owner.exercise() == 53)
    }
}

private final class LocalState {
    var number = 0
}

private actor ContextOwner {
    private var number = 0

    func exercise() async -> Int {
        await withChildren { (children: borrowing Children) in
            number = 50
            let child = children.start {
                3
            }

            number += await child.value()

            return number
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RetentionTests {
    @Test func capturesAreReleasedAfterScopeAndActualOwnersFinish() async {
        let reference = WeakReference()
        await finishScopeWithCapture(reference)
        #expect(await reference.isReleased)
    }

    @Test func escapedHandleRetainsOutcomeUntilHandleIsDropped() async {
        let reference = WeakReference()
        var handle: Child<ReferencePayload, Never>? = await makeRetainedHandle(reference)
        #expect(!(await reference.isReleased))
        #expect(await readNumber(handle) == 59)
        handle = nil
        #expect(await reference.isReleased)
    }
}

private actor WeakReference {
    private weak var value: ReferencePayload?

    var isReleased: Bool {
        value == nil
    }

    func store(_ value: ReferencePayload) {
        self.value = value
    }
}

private func finishScopeWithCapture(_ observer: WeakReference) async {
    let capture = ReferencePayload(57)
    await observer.store(capture)
    await withChildren { (children: borrowing Children) in
        _ = children.start {
            capture.number
        }
    }
}

private func makeRetainedHandle(_ observer: WeakReference) async -> Child<ReferencePayload, Never> {
    await withChildren { (children: borrowing Children) in
        children.start {
            let reference = ReferencePayload(59)
            await observer.store(reference)

            return reference
        }
    }
}

private func readNumber(_ child: Child<ReferencePayload, Never>?) async -> Int? {
    await child?.value().number
}
