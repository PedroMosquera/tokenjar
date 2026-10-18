#if os(Windows)
import Foundation
import WinSDK

/// A CLI started by Tokenjar on Windows, in place of Foundation's Process, which gives every console program a console
/// window of its own (from the tray, one flashing up at each refresh), lets a process started at the same moment inherit
/// this one's pipe handles (so its output never reaches EOF), and when stopped leaves running whatever the CLI started,
/// such as the node behind an npm install. This one has no window, inherits only its own three handles, and runs in a job
/// object that ends the whole tree with it.
final class WindowsChildProcess: @unchecked Sendable {
    /// This side's ends of the child's stdin, stdout and, when captured, stderr.
    let input: FileHandle
    let output: FileHandle
    let errorOutput: FileHandle?
    private let process: HANDLE
    private let job: HANDLE

    /// `captureErrors` false sends stderr to NUL. `executable` is a program or an npm .cmd shim, never another script.
    init(executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?, captureErrors: Bool) throws {
        let (program, arguments) = try Self.resolve(executable, arguments: arguments, environment: environment)
        let stdin = try Self.pipe(childEnd: .read)
        let stdout = try Self.pipe(childEnd: .write)
        let stderr = try captureErrors ? Self.pipe(childEnd: .write) : nil
        let null = try captureErrors ? nil : Self.inheritableNull()
        let childError = stderr?.child ?? null!
        // The child's ends belong to it once it starts; this side keeps only its own.
        defer {
            CloseHandle(stdin.child)
            CloseHandle(stdout.child)
            CloseHandle(childError)
        }

        guard let job = CreateJobObjectW(nil, nil) else { throw WindowsProcessError.call("CreateJobObjectW", GetLastError()) }
        var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
        guard SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, DWORD(MemoryLayout.size(ofValue: limits))) else {
            let error = GetLastError()
            CloseHandle(job)
            throw WindowsProcessError.call("SetInformationJobObject", error)
        }

        let started: PROCESS_INFORMATION
        do {
            started = try Self.create(
                executable: program, arguments: arguments, environment: environment, currentDirectory: currentDirectory,
                handles: [stdin.child, stdout.child, childError]
            )
        } catch {
            CloseHandle(job)
            [stdin.parent, stdout.parent, stderr?.parent].compactMap { $0 }.forEach { CloseHandle($0) }
            throw error
        }
        // Started suspended, so nothing it starts can run before the job holds it.
        guard AssignProcessToJobObject(job, started.hProcess) else {
            let error = GetLastError()
            TerminateProcess(started.hProcess, 1)
            CloseHandle(started.hThread)
            CloseHandle(started.hProcess)
            CloseHandle(job)
            [stdin.parent, stdout.parent, stderr?.parent].compactMap { $0 }.forEach { CloseHandle($0) }
            throw WindowsProcessError.call("AssignProcessToJobObject", error)
        }
        ResumeThread(started.hThread)
        CloseHandle(started.hThread)

        self.job = job
        process = started.hProcess
        input = try Self.fileHandle(owning: stdin.parent)
        output = try Self.fileHandle(owning: stdout.parent)
        errorOutput = try stderr.map { try Self.fileHandle(owning: $0.parent) }
    }

    /// FileHandle takes a HANDLE only internally. A C runtime descriptor is the public way in, and FileHandle takes the
    /// handle over from it, closing it when released.
    private static func fileHandle(owning handle: HANDLE) throws -> FileHandle {
        let descriptor = _open_osfhandle(Int(bitPattern: handle), Int32(_O_BINARY))
        guard descriptor != -1 else {
            CloseHandle(handle)
            throw WindowsProcessError.call("_open_osfhandle", DWORD(GetLastError()))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        CloseHandle(process)
        // Closing the last handle to the job ends whatever still runs in it.
        CloseHandle(job)
    }

    var isRunning: Bool { WaitForSingleObject(process, 0) == DWORD(WAIT_TIMEOUT) }

    /// Blocks until the child exits, then returns its exit code.
    func waitForExit() -> Int32 {
        WaitForSingleObject(process, INFINITE)
        var code: DWORD = 0
        GetExitCodeProcess(process, &code)
        return Int32(bitPattern: UInt32(code))
    }

    /// Ends the child and everything it started. Safe to call more than once.
    func terminate() {
        TerminateJobObject(job, 1)
    }

    /// An npm shim becomes what it starts, so cmd.exe never parses the arguments. A program runs as given.
    private static func resolve(_ executable: URL, arguments: [String], environment: [String: String]) throws -> (URL, [String]) {
        guard executable.pathExtension.lowercased() == "cmd" else { return (executable, arguments) }
        guard let text = try? String(contentsOf: executable, encoding: .utf8),
              let target = NpmShim.target(of: text, in: executable.deletingLastPathComponent())
        else { throw WindowsProcessError.unreadableShim(executable.lastPathComponent) }
        switch target {
        case .program(let program):
            return (program, arguments)
        case .node(let script):
            // cmd-shim's own order: a node.exe beside the shim, else the first on the PATH.
            let path = environment.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
            let folders = [executable.deletingLastPathComponent()] + path.split(separator: ";").map { URL(fileURLWithPath: String($0)) }
            guard let node = folders.map({ $0.appending(path: "node.exe") }).first(where: { FileManager.default.fileExists(atPath: $0.path) })
            else { throw WindowsProcessError.nodeNotFound(executable.lastPathComponent) }
            return (node, [windowsPath(script)] + arguments)
        }
    }

    private enum ChildEnd { case read, write }

    private static func pipe(childEnd: ChildEnd) throws -> (parent: HANDLE, child: HANDLE) {
        var read: HANDLE?, write: HANDLE?
        guard CreatePipe(&read, &write, nil, 0), let read, let write else { throw WindowsProcessError.call("CreatePipe", GetLastError()) }
        let child = childEnd == .read ? read : write
        guard SetHandleInformation(child, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT)) else {
            let error = GetLastError()
            CloseHandle(read)
            CloseHandle(write)
            throw WindowsProcessError.call("SetHandleInformation", error)
        }
        return childEnd == .read ? (write, read) : (read, write)
    }

    private static func inheritableNull() throws -> HANDLE {
        var attributes = SECURITY_ATTRIBUTES(nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size), lpSecurityDescriptor: nil, bInheritHandle: true)
        let handle = "NUL".withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &attributes, DWORD(OPEN_EXISTING), 0, nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { throw WindowsProcessError.call("CreateFileW", GetLastError()) }
        return handle
    }

    private static func create(
        executable: URL, arguments: [String], environment: [String: String], currentDirectory: URL?, handles: [HANDLE]
    ) throws -> PROCESS_INFORMATION {
        // PROC_THREAD_ATTRIBUTE_HANDLE_LIST, a macro Swift does not import: the only handles the child inherits.
        let handleListAttribute = DWORD_PTR(0x0002_0002)
        var size: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { storage.deallocate() }
        let list = OpaquePointer(storage)
        guard InitializeProcThreadAttributeList(list, 1, 0, &size) else {
            throw WindowsProcessError.call("InitializeProcThreadAttributeList", GetLastError())
        }
        defer { DeleteProcThreadAttributeList(list) }
        // UpdateProcThreadAttribute keeps the pointer, so the list must outlive CreateProcessW.
        let inherited = UnsafeMutablePointer<HANDLE?>.allocate(capacity: handles.count)
        defer { inherited.deallocate() }
        for (index, handle) in handles.enumerated() { inherited[index] = handle }
        guard UpdateProcThreadAttribute(list, 0, handleListAttribute, inherited, SIZE_T(MemoryLayout<HANDLE?>.stride * handles.count), nil, nil) else {
            throw WindowsProcessError.call("UpdateProcThreadAttribute", GetLastError())
        }

        var info = STARTUPINFOEXW()
        info.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
        info.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
        info.StartupInfo.hStdInput = handles[0]
        info.StartupInfo.hStdOutput = handles[1]
        info.StartupInfo.hStdError = handles[2]
        info.lpAttributeList = list

        let program = windowsPath(executable)
        var commandLine = Array((([program] + arguments).map(quoteArgument).joined(separator: " ")).utf16) + [0]
        var block = environmentBlock(environment)
        let directory = currentDirectory.map(windowsPath)
        let flags = DWORD(CREATE_SUSPENDED) | DWORD(CREATE_NO_WINDOW) | DWORD(CREATE_UNICODE_ENVIRONMENT) | DWORD(EXTENDED_STARTUPINFO_PRESENT)

        var started = PROCESS_INFORMATION()
        let ok = program.withCString(encodedAs: UTF16.self) { programName in
            withOptionalWide(directory) { directoryName in
                withUnsafeMutablePointer(to: &info) { infoPointer in
                    infoPointer.withMemoryRebound(to: STARTUPINFOW.self, capacity: 1) { startup in
                        CreateProcessW(programName, &commandLine, nil, nil, true, flags, &block, directoryName, startup, &started)
                    }
                }
            }
        }
        guard ok else { throw WindowsProcessError.call("CreateProcessW", GetLastError()) }
        return started
    }

    /// `KEY=value` strings, each NUL-terminated, sorted by name ignoring case as CreateProcessW asks, then one more NUL.
    static func environmentBlock(_ environment: [String: String]) -> [UInt16] {
        let entries = environment.sorted { $0.key.uppercased() < $1.key.uppercased() }
        var block: [UInt16] = []
        for (key, value) in entries { block += Array("\(key)=\(value)".utf16) + [0] }
        if block.isEmpty { block.append(0) }
        return block + [0]
    }

    /// One argument as the C runtime's parser reads it back: quoted when it holds a space, tab, newline or quote, with
    /// backslashes doubled only where they precede a quote.
    static func quoteArgument(_ argument: String) -> String {
        guard argument.isEmpty || argument.contains(where: { " \t\n\"".contains($0) }) else { return argument }
        var quoted = "\""
        var backslashes = 0
        for character in argument {
            if character == "\\" {
                backslashes += 1
                continue
            }
            if character == "\"" {
                quoted += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
            } else {
                quoted += String(repeating: "\\", count: backslashes) + String(character)
            }
            backslashes = 0
        }
        return quoted + String(repeating: "\\", count: backslashes * 2) + "\""
    }

    private static func withOptionalWide<Result>(_ text: String?, _ body: (UnsafePointer<UInt16>?) -> Result) -> Result {
        guard let text else { return body(nil) }
        return text.withCString(encodedAs: UTF16.self) { body($0) }
    }
}

/// The path in the form Windows APIs take: drive letter first, backslashes.
func windowsPath(_ url: URL) -> String {
    url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
}

enum WindowsProcessError: Error, CustomStringConvertible {
    case call(String, DWORD)
    /// A .cmd that is not an npm shim this can read, so it would have to go through cmd.exe.
    case unreadableShim(String)
    case nodeNotFound(String)

    var description: String {
        switch self {
        case .call(let function, let code): "\(function) failed with Windows error \(code)"
        case .unreadableShim(let name): "\(name) is not an npm shim Tokenjar can read"
        case .nodeNotFound(let name): "node.exe, which \(name) needs, is not beside it or on the PATH"
        }
    }
}

extension FoundationProcessRunner {
    /// `run` on Windows, through `WindowsChildProcess`.
    func runWithoutConsole(
        _ executable: URL, arguments: [String], environment: [String: String],
        currentDirectory: URL?, stdin: Data?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> ProcessResult {
        let child = try WindowsChildProcess(
            executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, captureErrors: true
        )
        let out = LimitedBuffer(limit: outputLimit), err = LimitedBuffer(limit: outputLimit)
        let drained = DispatchGroup()
        for (handle, buffer) in [(child.output, out), (child.errorOutput!, err)] {
            drained.enter()
            readUntilEOF(handle, onData: buffer.append) { if buffer.finish() { drained.leave() } }
        }
        if let stdin { try? child.input.write(contentsOf: stdin) }
        try? child.input.close()

        let exitCode = ExitCode()
        let exited = DispatchGroup()
        exited.enter()
        Thread.detachNewThread {
            exitCode.value = child.waitForExit()
            exited.leave()
        }
        let timedOut = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await exited.done()
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return true
            }
            let first = await group.next() ?? false
            if first { child.terminate() }
            group.cancelAll()
            return first
        }
        await exited.done()
        await drained.done()
        return ProcessResult(exitCode: exitCode.value, stdout: out.data, stderr: err.data, timedOut: timedOut)
    }
}

private final class ExitCode: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32 = 0
    var value: Int32 {
        get { lock.withLock { code } }
        set { lock.withLock { code = newValue } }
    }
}
#endif
