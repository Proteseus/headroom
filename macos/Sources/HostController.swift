import AppKit
import Foundation

/// Locates the bundled Python host and installs/starts it as a LaunchAgent so
/// the menu bar (and optional ESP32) keep working after the app quits.
enum HostController {
    static let label = "com.mz.headroom"
    static let defaultPort = 8737

    private static var domain: String { "gui/\(getuid())" }

    /// `…/Contents/Resources/host` or `…/Resources/EmbeddedHost/host`
    static var bundledHostDirectory: URL? {
        let fm = FileManager.default
        let bases = [
            Bundle.main.resourceURL?.appendingPathComponent("host", isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent(
                "EmbeddedHost/host", isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent(
                "EmbeddedHost", isDirectory: true),
        ]
        for base in bases {
            guard let base else { continue }
            let server = base.appendingPathComponent("headroom_server.py")
            if fm.isfile(server.path) { return base }
        }
        return nil
    }

    static var bundledServer: URL? {
        guard let dir = bundledHostDirectory else { return nil }
        let server = dir.appendingPathComponent("headroom_server.py")
        return FileManager.default.isfile(server.path) ? server : nil
    }

    static var pythonURL: URL {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3",
                          "/usr/local/bin/python3"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isBundled: Bool { bundledServer != nil }

    static func healthURL(port: Int = defaultPort) -> URL {
        URL(string: "http://127.0.0.1:\(port)/health")!
    }

    static func isReachable(port: Int = defaultPort) async -> Bool {
        var request = URLRequest(url: healthURL(port: port))
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Write LaunchAgent pointing at the bundled host and kickstart it.
    @discardableResult
    static func installAndStart(port: Int = defaultPort) throws -> String {
        guard let server = bundledServer, let hostDir = bundledHostDirectory else {
            throw HostError.notBundled
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = (home as NSString).appendingPathComponent(".headroom/logs")
        try FileManager.default.createDirectory(
            atPath: logDir, withIntermediateDirectories: true)

        seedConfigIfNeeded()

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(pythonURL.path)</string>
            <string>\(server.path)</string>
            <string>--port</string>
            <string>\(port)</string>
          </array>
          <key>WorkingDirectory</key>
          <string>\(hostDir.path)</string>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>ThrottleInterval</key>
          <integer>5</integer>
          <key>StandardOutPath</key>
          <string>\(logDir)/headroom.log</string>
          <key>StandardErrorPath</key>
          <string>\(logDir)/headroom.err</string>
          <key>EnvironmentVariables</key>
          <dict>
            <key>PATH</key>
            <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
          </dict>
        </dict>
        </plist>
        """

        let agents = (home as NSString).appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(
            atPath: agents, withIntermediateDirectories: true)
        try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)

        _ = runLaunchctl(["bootout", "\(domain)/\(label)"])
        let bootstrap = runLaunchctl(["bootstrap", domain, launchAgentURL.path])
        if bootstrap.status != 0 && bootstrap.status != 36 {
            // 36 = already loaded in some OS versions after partial install.
            throw HostError.launchctl(
                bootstrap.stderr.isEmpty ? bootstrap.stdout : bootstrap.stderr)
        }
        _ = runLaunchctl(["enable", "\(domain)/\(label)"])
        let kick = runLaunchctl(["kickstart", "-k", "\(domain)/\(label)"])
        if kick.status != 0 {
            throw HostError.launchctl(
                kick.stderr.isEmpty ? kick.stdout : kick.stderr)
        }
        return launchAgentURL.path
    }

    /// Wait until /health answers (or timeout).
    static func waitUntilReady(port: Int = defaultPort, attempts: Int = 40) async -> Bool {
        for _ in 0..<attempts {
            if await isReachable(port: port) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    static func uninstall() {
        _ = runLaunchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    private static func seedConfigIfNeeded() {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".headroom/config.json")
        guard !FileManager.default.fileExists(atPath: config.path) else { return }
        let example = bundledHostDirectory?
            .appendingPathComponent("config.example.json")
        let folder = config.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let example, FileManager.default.fileExists(atPath: example.path) {
            try? FileManager.default.copyItem(at: example, to: config)
        } else {
            try? "{}\n".write(to: config, atomically: true, encoding: .utf8)
        }
    }

    private static func runLaunchctl(_ args: [String]) -> (
        status: Int32, stdout: String, stderr: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, "", error.localizedDescription)
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    enum HostError: LocalizedError {
        case notBundled
        case launchctl(String)

        var errorDescription: String? {
            switch self {
            case .notBundled:
                return "This build has no bundled host. Use ./scripts/install-host.sh from a clone, or download a Release build."
            case let .launchctl(message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "launchctl failed" : trimmed
            }
        }
    }
}

private extension FileManager {
    func isfile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }
}
