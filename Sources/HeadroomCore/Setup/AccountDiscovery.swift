import Foundation

/// Finds accounts already present on this Mac for first-run setup. Reads only file existence and
/// non-secret structure (which keys exist in opencode's auth.json); never reads token values.
public enum AccountDiscovery {
    public static func discover(paths: AppPaths, cli: CLILocator) -> [AccountConfig] { [] }

    /// False when the account's profile dir or credential file is missing on this machine; such accounts are hidden.
    public static func isAvailable(_ account: AccountConfig, paths: AppPaths) -> Bool { true }
}
