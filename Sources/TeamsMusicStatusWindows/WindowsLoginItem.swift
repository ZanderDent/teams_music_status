import Foundation
import TeamsMusicStatusCore
import WinSDK

/// Launch at login, via the per-user `Run` key.
///
/// The Windows counterpart of `LoginItemService`. `HKEY_CURRENT_USER` deliberately, never
/// `HKEY_LOCAL_MACHINE`: the per-user key needs no elevation, applies only to the person
/// who asked for it, and is the one Windows' own Startup Apps settings page shows — so a
/// user who changes their mind can turn it off where they expect to, without this app.
public enum WindowsLoginItem {

    /// The value name under `Run`. Also what Task Manager and Settings display.
    private static let valueName = "TeamsMusicStatus"
    private static let runKeyPath = #"Software\Microsoft\Windows\CurrentVersion\Run"#

    /// `HKEY_CURRENT_USER` as a raw handle. The Windows headers define it as a cast
    /// constant, which does not always survive into Swift as a usable value.
    private static var currentUser: HKEY? { HKEY(bitPattern: Int(bitPattern: 0x8000_0001)) }

    /// Whether launch at login can work for this build.
    ///
    /// False when running the raw SwiftPM binary out of `.build`, because registering that
    /// path would break as soon as the directory is cleaned — and would silently point at
    /// a debug build forever. The UI hides the control rather than offering something that
    /// cannot work, matching the macOS behaviour for an unbundled binary.
    public static var isSupported: Bool {
        !executablePath.lowercased().contains(#"\.build\"#)
    }

    public static var executablePath: String {
        var buffer = [UInt16](repeating: 0, count: Int(MAX_PATH) + 1)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard length > 0 else { return CommandLine.arguments.first ?? "" }
        return String(decoding: buffer[..<Int(length)], as: UTF16.self)
    }

    public static var isEnabled: Bool {
        read() != nil
    }

    /// The command line currently registered, if any.
    public static func read() -> String? {
        guard let root = currentUser else { return nil }
        var key: HKEY?
        guard RegOpenKeyExW(root, runKeyPath.wide, 0, DWORD(KEY_QUERY_VALUE), &key) == ERROR_SUCCESS,
              let key else { return nil }
        defer { RegCloseKey(key) }

        var type: DWORD = 0
        var size: DWORD = 0
        guard RegQueryValueExW(key, valueName.wide, nil, &type, nil, &size) == ERROR_SUCCESS,
              size > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(size))
        let status = buffer.withUnsafeMutableBufferPointer { raw in
            RegQueryValueExW(key, valueName.wide, nil, &type, raw.baseAddress, &size)
        }
        guard status == ERROR_SUCCESS else { return nil }

        let text = buffer.withUnsafeBytes { raw -> String in
            let units = raw.bindMemory(to: UInt16.self)
            let end = units.firstIndex(of: 0) ?? units.count
            return String(decoding: units[..<end], as: UTF16.self)
        }
        return text.isEmpty ? nil : text
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Result<Void, Error> {
        guard isSupported else {
            return .failure(LoginItemError.unsupported)
        }
        guard let root = currentUser else { return .failure(LoginItemError.registry(0)) }

        var key: HKEY?
        let access = DWORD(KEY_SET_VALUE) | DWORD(KEY_QUERY_VALUE)
        let opened = RegCreateKeyExW(root, runKeyPath.wide, 0, nil,
                                     DWORD(REG_OPTION_NON_VOLATILE), access, nil, &key, nil)
        guard opened == ERROR_SUCCESS, let key else {
            return .failure(LoginItemError.registry(Int32(opened)))
        }
        defer { RegCloseKey(key) }

        if enabled {
            // Quoted: the install path contains spaces (Program Files), and an unquoted
            // Run value is parsed at the first space, which silently launches the wrong
            // thing or nothing at all.
            let command = "\"\(executablePath)\""
            var units = Array(command.utf16)
            units.append(0)
            let byteCount = DWORD(units.count * MemoryLayout<UInt16>.size)

            let status = units.withUnsafeBufferPointer { buffer -> LSTATUS in
                buffer.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: Int(byteCount)) { bytes in
                    RegSetValueExW(key, valueName.wide, 0, DWORD(REG_SZ), bytes, byteCount)
                }
            }
            guard status == ERROR_SUCCESS else { return .failure(LoginItemError.registry(Int32(status))) }
            Log.app.info("launch at login enabled")
        } else {
            let status = RegDeleteValueW(key, valueName.wide)
            // Already absent is success, not failure — turning off something that is
            // already off is what the user asked for.
            guard status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND else {
                return .failure(LoginItemError.registry(Int32(status)))
            }
            Log.app.info("launch at login disabled")
        }
        return .success(())
    }

    public enum LoginItemError: LocalizedError {
        case unsupported
        case registry(Int32)

        public var errorDescription: String? {
            switch self {
            case .unsupported:
                return "Launch at login is only available for an installed build, "
                     + "not when running directly from the build directory."
            case .registry(let code):
                return "Windows refused the startup registration (error \(code))."
            }
        }
    }
}

extension String {
    /// A NUL-terminated UTF-16 buffer, for the wide Win32 entry points.
    var wide: [UInt16] { Array(utf16) + [0] }
}
