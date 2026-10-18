import Foundation
#if os(Windows)
import WinSDK
#endif

#if !os(Windows)
// Windows has no signals, and starts its CLIs through WindowsChildProcess rather than Process.

/// Stops a write to `handle` after its reader exits from raising SIGPIPE, which would kill the whole process.
/// Linux has no per-descriptor flag, so there it ignores SIGPIPE for the entire process: writes fail with EPIPE instead.
func preventSIGPIPE(writingTo handle: FileHandle) {
    #if canImport(Darwin)
    _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    #else
    _ = signal(SIGPIPE, SIG_IGN)
    #endif
}

/// Starts `process`. On Linux a child keeps the signal mask of the thread that spawns it, even across exec, and GCD and
/// Swift concurrency threads block nearly every signal there, so the CLI would never see a timeout's SIGTERM.
func launch(_ process: Process) throws {
    #if canImport(Darwin)
    try process.run()
    #else
    var none = sigset_t(), saved = sigset_t()
    sigemptyset(&none)
    pthread_sigmask(SIG_SETMASK, &none, &saved)
    defer { pthread_sigmask(SIG_SETMASK, &saved, nil) }
    try process.run()
    #endif
}
#endif

/// Hands each chunk read from `handle` to `onData` in order, then calls `atEOF` once.
/// On Linux a readabilityHandler was seen to miss a pipe's EOF, so a process run never finished; Linux reads on a thread
/// of its own instead, which a blocking read ties up until EOF.
func readUntilEOF(_ handle: FileHandle, onData: @escaping @Sendable (Data) -> Void, atEOF: @escaping @Sendable () -> Void) {
    #if canImport(Darwin)
    handle.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard chunk.isEmpty else { return onData(chunk) }
        // At EOF the handler fires again and again until removed.
        handle.readabilityHandler = nil
        atEOF()
    }
    #elseif os(Windows)
    // ReadFile on a pipe returns once any bytes arrive. A broken pipe, the writer closing its end, is the pipe's EOF.
    Thread.detachNewThread {
        var bytes = [UInt8](repeating: 0, count: 1 << 16)
        var count: DWORD = 0
        while ReadFile(handle._handle, &bytes, DWORD(bytes.count), &count, nil), count > 0 {
            onData(Data(bytes[..<Int(count)]))
        }
        atEOF()
    }
    #else
    // read(2) rather than FileHandle: there availableData traps on EINTR, and read(upToCount:) keeps reading until it
    // has the whole count, holding back a server's replies. Any error other than EINTR ends the stream like EOF.
    Thread.detachNewThread {
        var bytes = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                onData(Data(bytes[..<count]))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        atEOF()
    }
    #endif
}

/// Whether a JSONSerialization number was a JSON `true` or `false`, which also arrive as NSNumber.
func isJSONBoolean(_ number: NSNumber) -> Bool {
    #if canImport(Darwin)
    CFGetTypeID(number) == CFBooleanGetTypeID()
    #else
    type(of: number) == type(of: NSNumber(value: true))
    #endif
}

/// The file's inode and size, or nil when it cannot be read. Windows has no inodes; there the file index stands in, which
/// Foundation reports only the low 32 bits of.
func fileIdentity(atPath path: String) -> (inode: UInt64, size: UInt64)? {
    #if os(Windows)
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let index = attributes[.systemFileNumber] as? UInt, let size = attributes[.size] as? UInt64 else { return nil }
    return (UInt64(index), size)
    #else
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return (UInt64(info.st_ino), UInt64(info.st_size))
    #endif
}

#if !canImport(ObjectiveC)
/// Without the Objective-C runtime nothing is autoreleased, so there is no pool to drain.
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result { try body() }
#endif

#if os(Windows)
/// The C runtime on Windows has rmdir only under a deprecated name.
func rmdir(_ path: String) -> Int32 { _rmdir(path) }

/// The C runtime on Windows has no memmem.
func memmem(_ haystack: UnsafeRawPointer, _ haystackCount: Int, _ needle: UnsafeRawPointer, _ needleCount: Int) -> UnsafeRawPointer? {
    guard needleCount > 0 else { return haystack }
    guard haystackCount >= needleCount else { return nil }
    for offset in 0...(haystackCount - needleCount) where memcmp(haystack + offset, needle, needleCount) == 0 {
        return haystack + offset
    }
    return nil
}
#endif
