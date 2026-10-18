import Foundation
import TokenjarCore
import WinSDK

/// The tray icon, its menu and the hidden window that receives their messages. Everything here runs on the main
/// thread, inside the message loop. Checks run in `RefreshEngine` off that thread, and each one ends by posting
/// `summaryReady`, so the window redraws with the engine's newest summary.
final class Tray {
    /// The window procedure is a C function and cannot capture, so it reaches the tray through this.
    nonisolated(unsafe) static var shared: Tray?

    private static let className = "TokenjarTray"
    private static let trayMessage = UINT(WM_APP) + 1
    private static let summaryReady = UINT(WM_APP) + 2
    private static let tickTimer: UINT_PTR = 1

    private enum Command: UINT_PTR {
        case refresh = 1, startAtLogin, openSettings, quit
        /// Plus the section's index.
        static let usagePage: UINT_PTR = 1_000
        static let retry: UINT_PTR = 2_000
    }

    private let engine: RefreshEngine
    private let paths: AppPaths
    private let latest = Latest()
    private let window: HWND
    private let taskbarCreated: UINT
    private var summary = TraySummary.empty
    private var icon: HICON?

    init?(engine: RefreshEngine, paths: AppPaths) {
        self.engine = engine
        self.paths = paths
        taskbarCreated = "TaskbarCreated".withCString(encodedAs: UTF16.self) { RegisterWindowMessageW($0) }
        let instance = GetModuleHandleW(nil)
        let created: HWND? = Self.className.withCString(encodedAs: UTF16.self) { name in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = trayWindowProcedure
            windowClass.hInstance = instance
            windowClass.lpszClassName = name
            guard RegisterClassExW(&windowClass) != 0 else { return nil }
            // A hidden top-level window rather than a message-only one: only top-level windows hear TaskbarCreated.
            return CreateWindowExW(0, name, name, 0, 0, 0, 0, 0, nil, nil, instance, nil)
        }
        guard let created else { return nil }
        window = created
    }

    static func alert(_ text: String) {
        text.withCString(encodedAs: UTF16.self) { text in
            "Tokenjar".withCString(encodedAs: UTF16.self) { title in
                _ = MessageBoxW(nil, text, title, UINT(MB_OK | MB_ICONERROR))
            }
        }
    }

    func start() {
        updateIcon(adding: true)
        // RefreshScheduler decides which accounts are due, so a tick a minute only asks.
        SetTimer(window, Self.tickTimer, 60_000, nil)
        refresh(force: false)
    }

    fileprivate func handle(_ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch message {
        case Self.trayMessage:
            let event = UINT(truncatingIfNeeded: lParam)
            if event == UINT(WM_LBUTTONUP) || event == UINT(WM_RBUTTONUP) { showMenu() }
            return 0
        case Self.summaryReady:
            if let newest = latest.take() {
                summary = newest
                updateIcon(adding: false)
            }
            return 0
        case UINT(WM_TIMER):
            refresh(force: false)
            return 0
        case UINT(WM_COMMAND):
            run(UINT_PTR(wParam & 0xFFFF))
            return 0
        case UINT(WM_DESTROY):
            removeIcon()
            PostQuitMessage(0)
            return 0
        case taskbarCreated:
            // Explorer restarted and forgot every tray icon.
            updateIcon(adding: true)
            return 0
        default:
            return nil
        }
    }

    // MARK: Checks

    private func refresh(force: Bool) {
        guard latest.beginTick() else { return }
        let engine = engine, latest = latest, target = WindowReference(window), ready = Self.summaryReady
        Task.detached {
            await engine.tick(force: force)
            latest.finishTick(with: await engine.summary())
            target.post(ready)
        }
    }

    private func retry(_ accountID: String) {
        let engine = engine, latest = latest, target = WindowReference(window), ready = Self.summaryReady
        Task.detached {
            await engine.retry(accountID: accountID)
            latest.offer(await engine.summary())
            target.post(ready)
        }
    }

    // MARK: Icon

    private func updateIcon(adding: Bool) {
        let newIcon = TrayIcon.make(text: summary.iconText, level: summary.level)
        var data = notifyData()
        data.uFlags = UINT(NIF_ICON | NIF_TIP | NIF_MESSAGE)
        data.uCallbackMessage = Self.trayMessage
        data.hIcon = newIcon
        withUnsafeMutableBytes(of: &data.szTip) { copy(summary.tooltip, into: $0) }
        if adding {
            _ = Shell_NotifyIconW(DWORD(NIM_ADD), &data)
        } else if !Shell_NotifyIconW(DWORD(NIM_MODIFY), &data) {
            _ = Shell_NotifyIconW(DWORD(NIM_ADD), &data)
        }
        if let icon { DestroyIcon(icon) }
        icon = newIcon
    }

    private func removeIcon() {
        var data = notifyData()
        _ = Shell_NotifyIconW(DWORD(NIM_DELETE), &data)
    }

    private func notifyData() -> NOTIFYICONDATAW {
        var data = NOTIFYICONDATAW()
        data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
        data.hWnd = window
        data.uID = 1
        return data
    }

    // MARK: Menu

    private func showMenu() {
        guard let menu = CreatePopupMenu() else { return }
        defer { DestroyMenu(menu) }
        for (index, section) in summary.sections.enumerated() {
            if index > 0 { appendSeparator(menu) }
            append(menu, section.title, enabled: false)
            for line in section.lines { append(menu, "    " + line, enabled: false) }
            if let problem = section.problem { append(menu, "    " + problem, enabled: false) }
            if section.isLatched { append(menu, "    Check again (runs one probe)", id: Command.retry + UINT_PTR(index)) }
            append(menu, "    Open usage page", id: Command.usagePage + UINT_PTR(index))
        }
        if summary.sections.isEmpty { append(menu, "No accounts found on this PC", enabled: false) }
        appendSeparator(menu)
        append(menu, "Refresh now", id: Command.refresh.rawValue)
        append(menu, "Start at login", id: Command.startAtLogin.rawValue, checked: StartAtLogin.isOn)
        append(menu, "Open settings folder", id: Command.openSettings.rawValue)
        appendSeparator(menu)
        append(menu, "Quit Tokenjar", id: Command.quit.rawValue)

        var point = POINT()
        GetCursorPos(&point)
        // Without the foreground switch the menu stays open after a click elsewhere; the empty message after it is
        // the documented fix for the menu closing at once the next time.
        SetForegroundWindow(window)
        _ = TrackPopupMenu(menu, UINT(TPM_RIGHTBUTTON), point.x, point.y, 0, window, nil)
        PostMessageW(window, UINT(WM_NULL), 0, 0)
    }

    private func run(_ id: UINT_PTR) {
        switch Command(rawValue: id) {
        case .refresh:
            refresh(force: true)
        case .startAtLogin:
            if !StartAtLogin.set(!StartAtLogin.isOn) { Self.alert("Tokenjar could not change its Start at login setting.") }
        case .openSettings:
            try? FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
            openInShell(windowsPath(paths.configDirectory))
        case .quit:
            DestroyWindow(window)
        case nil:
            let sections = summary.sections
            if (Command.retry..<Command.retry + UINT_PTR(sections.count)).contains(id) {
                retry(sections[Int(id - Command.retry)].accountID)
            } else if (Command.usagePage..<Command.usagePage + UINT_PTR(sections.count)).contains(id) {
                // resolvedDashboardURL is always http or https, so this opens the browser and nothing else.
                openInShell(sections[Int(id - Command.usagePage)].usagePage.absoluteString)
            }
        }
    }

    private func openInShell(_ target: String) {
        target.withCString(encodedAs: UTF16.self) { target in
            "open".withCString(encodedAs: UTF16.self) { verb in
                _ = ShellExecuteW(window, verb, target, nil, nil, Int32(SW_SHOWNORMAL))
            }
        }
    }

    private func appendSeparator(_ menu: HMENU) {
        _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    }

    private func append(_ menu: HMENU, _ text: String, id: UINT_PTR = 0, enabled: Bool = true, checked: Bool = false) {
        var flags = UINT(MF_STRING)
        if !enabled { flags |= UINT(MF_DISABLED) }
        if checked { flags |= UINT(MF_CHECKED) }
        // A lone & marks the next letter as the item's shortcut.
        let escaped = text.replacingOccurrences(of: "&", with: "&&")
        _ = escaped.withCString(encodedAs: UTF16.self) { AppendMenuW(menu, flags, id, $0) }
    }

    /// Copies `text` into a fixed WCHAR array, cut to fit and always terminated.
    private func copy(_ text: String, into buffer: UnsafeMutableRawBufferPointer) {
        let units = buffer.bindMemory(to: UInt16.self)
        let fitting = Array(text.utf16.prefix(units.count - 1))
        for (index, unit) in fitting.enumerated() { units[index] = unit }
        units[fitting.count] = 0
    }
}

private func trayWindowProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    Tray.shared?.handle(message, wParam, lParam) ?? DefWindowProcW(window, message, wParam, lParam)
}

/// The newest summary from a check, handed from the check's thread to the main thread.
private final class Latest: @unchecked Sendable {
    private let lock = NSLock()
    private var summary: TraySummary?
    private var ticking = false

    /// False while a tick runs: a timer tick or a second Refresh now during one would only ask the same questions.
    func beginTick() -> Bool {
        lock.withLock {
            guard !ticking else { return false }
            ticking = true
            return true
        }
    }

    func finishTick(with summary: TraySummary) {
        lock.withLock {
            ticking = false
            self.summary = summary
        }
    }

    func offer(_ summary: TraySummary) {
        lock.withLock { self.summary = summary }
    }

    func take() -> TraySummary? {
        lock.withLock {
            defer { summary = nil }
            return summary
        }
    }
}

/// A window handle that a check's task can post to. PostMessageW may be called from any thread.
private struct WindowReference: @unchecked Sendable {
    let window: HWND

    init(_ window: HWND) { self.window = window }

    func post(_ message: UINT) {
        PostMessageW(window, message, 0, 0)
    }
}
