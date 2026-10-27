# Measured costs

ChildrenOfTasks' cost fixture measures bounded scopes against the archived handwritten native-task-group plus typed-actor-cell prototype. Both provide one execution per start, stored typed outcomes, repeated reads, and cancellation plus joining on scope exit. The control is copied into `Benchmarks/Control.swift`; only declaration names, documentation, and formatting differ from the archived implementation. This is a nearby equivalent implementation, not an `async let` comparison.

Run from the repository root with Xcode's Swift compiler and Python 3:

```sh
python3 Scripts/measure-costs.py --output /tmp/childrenoftasks-costs
```

Use `--output PATH`, `--counts 100 1000 10000`, and `--samples 5` to select the evidence directory and fixture sizes. The runner builds two separate optimized dynamic modules and an optimized consumer, checks all result checksums, and verifies that source hashes did not change during measurement. It needs no package-factory tooling or additional dependencies. Each fixture process has a 180-second failure bound.

## Recorded run

The recorded candidate used the pre-rename `Children` module. The tables and source identities below preserve that historical name and the original `Sources/Children/` paths; current runs use `ChildrenOfTasks` and `Sources/ChildrenOfTasks/`.

The October 27, 2026 run used a MacBookPro18,2 with Apple M1 Max and 64 GiB RAM, macOS 26.6.2 (25G83), and Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, clang 2100.3.34.1). The target was `arm64-apple-macosx13.0` with macOS SDK 27.0 from Xcode 27.1 (27A9275). Builds used `-O -swift-version 6 -strict-concurrency=complete`, separate module boundaries, and no WMO, LTO, upcoming/experimental features, or default-isolation override. This run is host cost evidence, not iOS cost or deployment evidence.

There were 24 processes: four workloads, three sizes, and two implementations. Each process performed one unrecorded warmup and five recorded samples. Times below are medians in milliseconds and include fixture bookkeeping, snapshots, and scope teardown. Result checksums are checked separately. Raw samples preserve their ranges; the smallest workloads are particularly sensitive to runtime and scheduling noise.

| Workload | Count | Children median ms | Control median ms |
| --- | ---: | ---: | ---: |
| creation-observation | 100 | 0.685 | 0.283 |
| creation-observation | 1,000 | 1.861 | 2.064 |
| creation-observation | 10,000 | 17.219 | 23.101 |
| fanout | 100 | 0.353 | 0.413 |
| fanout | 1,000 | 2.188 | 1.753 |
| fanout | 10,000 | 14.347 | 15.244 |
| retained-handles | 100 | 0.435 | 0.383 |
| retained-handles | 1,000 | 2.512 | 2.411 |
| retained-handles | 10,000 | 19.205 | 20.282 |
| short-lived | 100 | 0.861 | 0.840 |
| short-lived | 1,000 | 5.472 | 5.131 |
| short-lived | 10,000 | 45.346 | 48.505 |

`creation-observation` starts all scalar children, retains their handles, then reads each result. `fanout` starts one scalar child and creates N native reader tasks sharing its handle. Readers can encounter pending or completed publication; this fixture does not force N suspended continuations. `retained-handles` returns N handles holding separate 1,024-byte payload arrays, observes them after scope exit, then drops every handle. Its payload counter uses a lock and synchronous deinitialization. `short-lived` starts and awaits each scalar child sequentially in one scope, without retaining a collection of handles.

## Memory and retention

Mach task info supplies current resident bytes. `/usr/bin/time -l` supplies peak resident bytes across the whole process, including warmup and all samples. `malloc_zone_statistics(nil, ...)` supplies actual live block counts, live bytes, and reserved bytes summed across allocator zones. These are process-wide snapshots, not cumulative allocation counts or allocations attributed to Children. The allocator's reported high-water field was zero in this run and is not used as a peak-memory measurement.

The following Children measurements use the median live-byte change from each sample's starting snapshot to the named phase. Peak RSS covers the entire corresponding process.

| 10,000-item workload and phase | Extra live malloc bytes | Process peak RSS MiB |
| --- | ---: | ---: |
| creation-observation: completed-in-scope | 14,884,384 | 21.47 |
| fanout: readers-completed-in-scope | 14,128 | 20.36 |
| retained-handles: handles-retained-after-scope | 14,482,176 | 34.83 |
| short-lived: completed-in-scope | 13,522,592 | 19.73 |

Sequentially observing and dropping handles does not keep a long scope's live memory flat: at the 5,001st operation, the median increase was 6,762,720 bytes, and at 10,000 completions it was approximately twice that. After scope exit, the median increase was 384 bytes, including measurement dictionaries. This is consistent with the native group's retained completed records and captures. It is a practical reason to keep scopes bounded. The snapshots do not separately identify task-record and cell allocations.

In every retained-handle sample, both implementations had exactly N live payload objects after scope exit and zero after dropping handles. Live malloc bytes then returned near their starting level. Resident memory often remained at its higher watermark because freed allocator storage can stay resident. RSS alone would therefore misidentify this case as retained outcomes.

Children's median times grew less than tenfold for each tenfold work increase in this run. The control's creation/observation case grew 11.2 times between 1,000 and 10,000 children. A targeted repeat with nine samples measured 2.058 ms and 16.081 ms respectively (7.8 times); the raw repeat is preserved as `scaling-check.json` and its sample files. These runs do not establish persistent superlinear growth. No indefinite payload retention was observed. Relative latency varies by workload and run; these results support no speedup claim or fixed capacity recommendation.

## Allocation model and limits

Source inspection identifies one group-storage object per scope, one actor cell and native task per child, and one checked continuation per read that suspends before publication. Handles retain completed cells and outcomes. These are source-derived structural counts, not measured allocation totals: runtime tasks, continuations, array growth, allocator rounding, and optimizer behavior can add or combine allocations.

The instrumentation measures live allocator state and payload ownership, but it does not count all allocation events or attribute them to individual runtime objects. A dedicated allocation trace would be needed for those claims. The fixture uses tiny successful operations, scalar outputs except in retention, and one host/compiler/runtime. It does not model application work, failures, cancellation-heavy workloads, iOS 16.4 execution, every reader-publication schedule, or latency under system load.

The selected output directory contains `costs.json`, per-case raw JSON samples, `/usr/bin/time -l` output, optimized modules, and the executable. The aggregate includes complete compiler/run commands, environment details, source SHA-256 values, and artifact SHA-256 values. The tables use the final source run; earlier development runs are excluded. Repeating the command above creates the same evidence layout at the chosen destination.

Production input identities for the recorded run:

| Source | SHA-256 |
| --- | --- |
| `Sources/Children/ChildResult.swift` | `772cb4c24e824c68f457fbe82a86ae1a716e0a4bbdd6c76eb4c6bf7db34aed07` |
| `Sources/Children/Children.swift` | `69e2989e3e0f4ac4f3bcd89a6f863e6728227d8c2b0485ac223f37f9ac53f7fd` |
