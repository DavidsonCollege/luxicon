import Foundation

/// Whether the iPhone-sync listener (`luxicon-mcp listen`) is available on
/// this Mac. Checks the LaunchAgent and the installed binary; there is no
/// network probe.
enum ListenerStatus: Equatable {
    case running, installedNotRunning, notInstalled

    static let launchAgentLabel = "edu.davidson.luxicon.listener"

    /// Where `scripts/install-listener.sh` and the installer package put the binary.
    static var binaryLocations: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/usr/local/bin/luxicon-mcp", "\(home)/bin/luxicon-mcp", "\(home)/.local/bin/luxicon-mcp"]
    }

    static func check() async -> ListenerStatus {
        await Task.detached(priority: .utility) { checkSync() }.value
    }

    private static func checkSync() -> ListenerStatus {
        if launchctlReportsRunning() { return .running }
        let installed = binaryLocations.contains { FileManager.default.isExecutableFile(atPath: $0) }
        return installed ? .installedNotRunning : .notInstalled
    }

    private static func launchctlReportsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(launchAgentLabel)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(separator: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == "state = running"
        }
    }
}
