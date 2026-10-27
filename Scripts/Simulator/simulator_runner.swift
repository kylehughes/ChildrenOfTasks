import Darwin
import Foundation
import Testing

private enum RecordOutput {
    static let lock = NSLock()
    static let handle: FileHandle = {
        guard let path = ProcessInfo.processInfo.environment["PACKAGE_EVENT_STREAM_PATH"] else {
            fatalError("Missing event stream destination")
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { fatalError("Cannot create event stream") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }()

    static func write(_ bytes: UnsafeRawBufferPointer) {
        var data = Data(bytes)
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        handle.write(data)
    }
}

private enum RunnerError: Error {
    case missingBundle
    case loadingFailed(String)
    case missingEntryPoint
}

@main
private struct TestingRunner {
    private typealias Getter = @convention(c) () -> UnsafeRawPointer
    private typealias EntryPoint =
        @convention(thin) @Sendable (
            UnsafeRawBufferPointer?,
            @escaping @Sendable (UnsafeRawBufferPointer) -> Void
        ) async throws -> Bool

    static func main() async {
        do {
            _ = RecordOutput.handle
            guard let bundle = ProcessInfo.processInfo.environment["PACKAGE_TEST_BUNDLE"] else {
                throw RunnerError.missingBundle
            }
            guard let handle = dlopen(bundle, RTLD_NOW | RTLD_GLOBAL) else {
                let message = dlerror().map { String(cString: $0) } ?? "Unknown loader failure"
                throw RunnerError.loadingFailed(message)
            }
            guard let symbol = dlsym(handle, "swt_abiv0_getEntryPoint") else {
                throw RunnerError.missingEntryPoint
            }
            let getter = unsafeBitCast(symbol, to: Getter.self)
            let entry = unsafeBitCast(getter(), to: EntryPoint.self)
            var arguments = __CommandLineArguments_v0()
            arguments.eventStreamSchemaVersion = "0"
            arguments.listTests = CommandLine.arguments[1] == "list"
            let filters = Array(CommandLine.arguments.dropFirst(2))
            arguments.filter = filters.isEmpty ? nil : filters
            let encoded = try JSONEncoder().encode(arguments)
            let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: encoded.count, alignment: 1)
            defer { storage.deallocate() }
            encoded.copyBytes(to: storage)
            let passed = try await entry(UnsafeRawBufferPointer(storage)) { bytes in
                RecordOutput.write(bytes)
            }
            exit(passed ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("Runner error: \(error)\n".utf8))
            exit(78)
        }
    }
}
