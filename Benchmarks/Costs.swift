import Baseline
import ChildrenOfTasks
import Darwin
import Foundation
import os

final class LivePayloads: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var live: Int {
        count.withLock {
            $0
        }
    }

    func add(_ delta: Int) {
        count.withLock {
            $0 += delta
        }
    }
}

final class Payload: Sendable {
    let bytes: [UInt8]
    private let live: LivePayloads
    init(_ seed: Int, live: LivePayloads) {
        bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: seed), count: 1_024)
        self.live = live
        live.add(1)
    }

    deinit {
        live.add(-1)
    }
}

struct MemorySnapshot: Codable {
    let residentBytes: UInt64
    let mallocBlocksInUse: UInt32
    let mallocBytesInUse: Int
    let mallocHighWaterBytes: Int
    let mallocReservedBytes: Int
}

func memorySnapshot() -> MemorySnapshot {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }

    precondition(status == KERN_SUCCESS)
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)

    return MemorySnapshot(
        residentBytes: info.resident_size,
        mallocBlocksInUse: statistics.blocks_in_use,
        mallocBytesInUse: statistics.size_in_use,
        mallocHighWaterBytes: statistics.max_size_in_use,
        mallocReservedBytes: statistics.size_allocated
    )
}

struct Observation: Codable {
    let checksum: Int
    let memory: [String: MemorySnapshot]
    let livePayloads: [String: Int]
}

func packageWorkload(_ workload: String, count: Int) async -> Observation {
    let baseline = memorySnapshot()
    var memory = ["before": baseline]
    var liveCounts: [String: Int] = [:]
    let live = LivePayloads()
    let checksum: Int
    switch workload {
    case "creation-observation":
        checksum = await withChildren {
            (children: borrowing Children) in
            var handles: [Child<Int, Never>] = []
            handles.reserveCapacity(count)
            for index in 0 ..< count {
                handles.append(
                    children.start {
                        index
                    }
                )
            }

            var total = 0
            for handle in handles {
                total += await handle.value()
            }

            memory["completed-in-scope"] = memorySnapshot()

            return total
        }

    case "short-lived":
        checksum = await withChildren {
            (children: borrowing Children) in
            var total = 0
            for index in 0 ..< count {
                total +=
                    await children.start {
                        index
                    }
                    .value()

                if index == count / 2 {
                    memory["mid-scope"] = memorySnapshot()
                }
            }

            memory["completed-in-scope"] = memorySnapshot()

            return total
        }

    case "fanout":
        checksum = await withChildren {
            (children: borrowing Children) in
            let handle = children.start {
                1
            }

            return await withTaskGroup(of: Int.self) {
                readers in
                for _ in 0 ..< count {
                    readers.addTask {
                        await handle.value()
                    }
                }

                var total = 0
                for await value in readers {
                    total += value
                }

                memory["readers-completed-in-scope"] = memorySnapshot()

                return total
            }
        }

    case "retained-handles":
        var handles: [Child<Payload, Never>] = await withChildren {
            (children: borrowing Children) in
            var handles: [Child<Payload, Never>] = []
            handles.reserveCapacity(count)
            for index in 0 ..< count {
                handles.append(
                    children.start {
                        Payload(index, live: live)
                    }
                )
            }

            return handles
        }

        memory["handles-retained-after-scope"] = memorySnapshot()
        liveCounts["handles-retained-after-scope"] = live.live
        var total = 0
        for handle in handles {
            total += Int(await handle.value().bytes[0])
        }

        handles.removeAll(keepingCapacity: false)
        memory["handles-dropped"] = memorySnapshot()
        liveCounts["handles-dropped"] = live.live
        precondition(live.live == 0, "Completed handles retained payloads after all handles were dropped")
        checksum = total
    default:
        preconditionFailure("Unknown workload")
    }

    memory["after"] = memorySnapshot()

    return Observation(checksum: checksum, memory: memory, livePayloads: liveCounts)
}

func baselineWorkload(_ workload: String, count: Int) async -> Observation {
    let baseline = memorySnapshot()
    var memory = ["before": baseline]
    var liveCounts: [String: Int] = [:]
    let live = LivePayloads()
    let checksum: Int
    switch workload {
    case "creation-observation":
        checksum = await Baseline.withControlChildren {
            (children: borrowing Baseline.ControlChildren) in
            var handles: [Baseline.ControlChild<Int, Never>] = []
            handles.reserveCapacity(count)
            for index in 0 ..< count {
                handles.append(
                    children.start {
                        index
                    }
                )
            }

            var total = 0
            for handle in handles {
                total += await handle.value()
            }

            memory["completed-in-scope"] = memorySnapshot()

            return total
        }

    case "short-lived":
        checksum = await Baseline.withControlChildren {
            (children: borrowing Baseline.ControlChildren) in
            var total = 0
            for index in 0 ..< count {
                total +=
                    await children.start {
                        index
                    }
                    .value()

                if index == count / 2 {
                    memory["mid-scope"] = memorySnapshot()
                }
            }

            memory["completed-in-scope"] = memorySnapshot()

            return total
        }

    case "fanout":
        checksum = await Baseline.withControlChildren {
            (children: borrowing Baseline.ControlChildren) in
            let handle = children.start {
                1
            }

            return await withTaskGroup(of: Int.self) {
                readers in
                for _ in 0 ..< count {
                    readers.addTask {
                        await handle.value()
                    }
                }

                var total = 0
                for await value in readers {
                    total += value
                }

                memory["readers-completed-in-scope"] = memorySnapshot()

                return total
            }
        }

    case "retained-handles":
        var handles: [Baseline.ControlChild<Payload, Never>] = await Baseline.withControlChildren {
            (children: borrowing Baseline.ControlChildren) in
            var handles: [Baseline.ControlChild<Payload, Never>] = []
            handles.reserveCapacity(count)
            for index in 0 ..< count {
                handles.append(
                    children.start {
                        Payload(index, live: live)
                    }
                )
            }

            return handles
        }

        memory["handles-retained-after-scope"] = memorySnapshot()
        liveCounts["handles-retained-after-scope"] = live.live
        var total = 0
        for handle in handles {
            total += Int(await handle.value().bytes[0])
        }

        handles.removeAll(keepingCapacity: false)
        memory["handles-dropped"] = memorySnapshot()
        liveCounts["handles-dropped"] = live.live
        precondition(live.live == 0, "Completed handles retained payloads after all handles were dropped")
        checksum = total
    default:
        preconditionFailure("Unknown workload")
    }

    memory["after"] = memorySnapshot()

    return Observation(checksum: checksum, memory: memory, livePayloads: liveCounts)
}

struct Sample: Codable {
    let milliseconds: Double
    let observation: Observation
}

@main struct CostBenchmark {
    static func main() async throws {
        let arguments = CommandLine.arguments
        precondition(arguments.count == 5, "backend workload count samples")
        let backend = arguments[1]
        let workload = arguments[2]
        guard let count = Int(arguments[3]), let samples = Int(arguments[4]), count > 0, samples > 0 else {
            preconditionFailure("Positive count and sample count required")
        }

        precondition(backend == "package" || backend == "baseline")
        var output: [Sample] = []
        for iteration in 0 ... samples {
            let start = ContinuousClock.now
            let observation =
                backend == "package"
                ? await packageWorkload(workload, count: count)
                : await baselineWorkload(workload, count: count)

            let duration = start.duration(to: .now).components
            let milliseconds = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
            let expected =
                workload == "fanout"
                ? count
                : workload == "retained-handles"
                    ? (0 ..< count)
                        .reduce(0) {
                            $0 + Int(UInt8(truncatingIfNeeded: $1))
                        }

                    : count * (count - 1) / 2

            precondition(observation.checksum == expected)
            if iteration > 0 {
                output.append(Sample(milliseconds: milliseconds, observation: observation))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
    }
}
