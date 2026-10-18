import WinSDK

/// Start at login is a value named Tokenjar under the current user's Run key, the entry Task Manager's Startup apps page
/// lists and can turn off. Only that one value is read or written.
enum StartAtLogin {
    private static let runKey = #"Software\Microsoft\Windows\CurrentVersion\Run"#
    private static let valueName = "Tokenjar"

    /// The HKEY_CURRENT_USER macro, which Swift does not import: (HKEY)(ULONG_PTR)(LONG)0x80000001, sign-extended.
    private static var currentUser: HKEY? { HKEY(bitPattern: Int(Int32(bitPattern: 0x8000_0001))) }

    /// On only while the value starts this copy, so a copy moved to another folder shows it off.
    static var isOn: Bool { stored() == command }

    /// False when the registry refused.
    static func set(_ on: Bool) -> Bool {
        runKey.withCString(encodedAs: UTF16.self) { key in
            valueName.withCString(encodedAs: UTF16.self) { name in
                guard on else {
                    let status = RegDeleteKeyValueW(currentUser, key, name)
                    return status == LSTATUS(ERROR_SUCCESS) || status == LSTATUS(ERROR_FILE_NOT_FOUND)
                }
                let data = Array(command.utf16) + [0]
                let status = data.withUnsafeBytes { RegSetKeyValueW(currentUser, key, name, DWORD(REG_SZ), $0.baseAddress, DWORD($0.count)) }
                return status == LSTATUS(ERROR_SUCCESS)
            }
        }
    }

    /// This program's path, quoted since it can hold spaces.
    private static var command: String {
        var buffer = [UInt16](repeating: 0, count: 32_768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        return "\"" + String(decoding: buffer[..<Int(length)], as: UTF16.self) + "\""
    }

    private static func stored() -> String? {
        runKey.withCString(encodedAs: UTF16.self) { key in
            valueName.withCString(encodedAs: UTF16.self) { name in
                var size: DWORD = 0
                guard RegGetValueW(currentUser, key, name, DWORD(RRF_RT_REG_SZ), nil, nil, &size) == LSTATUS(ERROR_SUCCESS), size > 0 else {
                    return nil
                }
                var buffer = [UInt16](repeating: 0, count: Int(size) / 2 + 1)
                guard RegGetValueW(currentUser, key, name, DWORD(RRF_RT_REG_SZ), nil, &buffer, &size) == LSTATUS(ERROR_SUCCESS) else { return nil }
                return String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
            }
        }
    }
}
