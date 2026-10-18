import Foundation
import TokenjarCore
import WinSDK

// A second copy would check every account twice and draw a second icon.
_ = "Local\\Tokenjar.Tray".withCString(encodedAs: UTF16.self) { CreateMutexW(nil, true, $0) }
if GetLastError() == DWORD(ERROR_ALREADY_EXISTS) { exit(0) }

// Without this Windows draws the icon at 16 pixels and stretches it, blurring the number.
_ = SetProcessDPIAware()

let paths = AppPaths()
let store: SQLiteUsageStore
do {
    try paths.createProbeDirectory()
    store = try SQLiteUsageStore(url: paths.databaseFile)
} catch {
    Tray.alert("Tokenjar could not open its history in \(windowsPath(paths.supportDirectory)).")
    exit(1)
}

guard let tray = Tray(engine: RefreshEngine(paths: paths, store: store), paths: paths) else {
    Tray.alert("Tokenjar could not add its icon to the taskbar.")
    exit(1)
}
Tray.shared = tray
tray.start()

var message = MSG()
while GetMessageW(&message, nil, 0, 0) {
    TranslateMessage(&message)
    DispatchMessageW(&message)
}
