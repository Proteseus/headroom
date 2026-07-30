import AppKit
import Foundation

/// Locates the bundled Python host and installs/starts it as a LaunchAgent so
/// the menu bar (and optional ESP32) keep working after the app quits.
enum HostController {
    static let label = "com.centaur-labs.headroom"
    /// Pre-rename label — retire on install so two agents don't fight over :8737.
    static let legacyLabel = "com.mz.headroom"
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

    /// What the iPhone pastes to pair. Written by the host on first run, so it
    /// is absent until the helper has started at least once.
    ///
    /// Not `~/.headroom/token` — that one is the host token the ESP32 uses, and
    /// the phone refuses it.
    static var mobileTokenURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".headroom/mobile-token")
    }

    static var mobileToken: String? {
        guard
            let value = try? String(contentsOf: mobileTokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }

    /// Fingerprint of the host this .app ships.
    ///
    /// Cached, but against the directory's stamp rather than for the life of the
    /// process. `Bundle.main` keeps pointing at the same path when the .app is
    /// replaced underneath a running copy — every rebuild during development,
    /// and a Finder copy over /Applications while the menu bar app is up. A
    /// value computed at launch outlives the bundle it described, and the app
    /// then reports its own staleness as the host's: a permanent "out of date"
    /// banner offering an update that reinstalls the very host already running.
    static var bundledBuild: String? { fingerprint()?.build }

    static var bundledVersion: String? { fingerprint()?.version }

    private static let fingerprints = FingerprintCache()

    private static func fingerprint() -> FingerprintCache.Entry? {
        guard let directory = bundledHostDirectory else { return nil }
        return fingerprints.entry(for: directory)
    }

    /// Version + build of a host directory, recomputed only when its files move.
    private final class FingerprintCache: @unchecked Sendable {
        struct Entry {
            var version: String?
            var build: String?
        }

        private let lock = NSLock()
        private var stamp: String?
        private var cached: Entry?

        func entry(for directory: URL) -> Entry? {
            let current = HostVersion.stamp(of: directory)
            lock.lock()
            if stamp == current, let cached {
                lock.unlock()
                return cached
            }
            lock.unlock()

            let fresh = Entry(
                version: HostVersion.version(in: directory),
                build: HostVersion.build(in: directory)
            )
            lock.lock()
            stamp = current
            cached = fresh
            lock.unlock()
            return fresh
        }
    }

    /// What's running vs. what this .app ships, or nil when they agree.
    ///
    /// Nil when there's nothing to compare against either: a debug build with no
    /// bundled host is a developer running the host from a clone, and nagging
    /// them about their own checkout would be noise.
    static func skew(against report: HealthReport) -> HostSkew? {
        guard let bundledBuild, let bundledVersion else { return nil }
        guard report.build != bundledBuild else { return nil }
        // Equal or unreadable release lines say nothing about direction; only a
        // strictly higher one proves the app is the stale half.
        let hostIsNewer = report.version
            .flatMap { HostVersion.isNewer($0, than: bundledVersion) } ?? false
        return HostSkew(
            runningVersion: report.version,
            runningBuild: report.build,
            bundledVersion: bundledVersion,
            bundledBuild: bundledBuild,
            hostIsNewer: hostIsNewer
        )
    }

    static func healthURL(port: Int = defaultPort) -> URL {
        URL(string: "http://127.0.0.1:\(port)/health")!
    }

    static func isReachable(port: Int = defaultPort) async -> Bool {
        await probe(port: port) != nil
    }

    /// One loopback /health read, or nil when nothing answered.
    private static func probe(port: Int = defaultPort) async -> HealthReport? {
        var request = URLRequest(url: healthURL(port: port))
        request.timeoutInterval = 1.5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return nil
            }
            // A body we can't read is still a host answering. Reachability must
            // not start depending on keys the oldest hosts never emitted.
            return (try? JSONDecoder().decode(HealthReport.self, from: data))
                ?? HealthReport(
                    ok: true, uptimeS: nil, updated: nil, sources: [:],
                    version: nil, build: nil)
        } catch {
            return nil
        }
    }

    /// Write LaunchAgent pointing at the bundled host and kickstart it.
    @discardableResult
    static func installAndStart(port: Int = defaultPort) throws -> String {
        guard let server = bundledServer else {
            throw HostError.notBundled
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let headroomDir = (home as NSString).appendingPathComponent(".headroom")
        let logDir = (headroomDir as NSString).appendingPathComponent("logs")
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
          <string>\(headroomDir)</string>
          <key>RunAtLoad</key>
          <true/>
          <!-- Not a plain <true/>. The host exits 0 on purpose when a foreign
               process already serves /health on this port; an unconditional
               KeepAlive respawns it every ThrottleInterval forever, each
               respawn rescanning a week of logs. Non-zero and signal deaths
               still come back. -->
          <key>KeepAlive</key>
          <dict>
            <key>SuccessfulExit</key>
            <false/>
          </dict>
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

        retireLegacyAgent()
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

    /// How a start attempt actually landed.
    enum Readiness: Equatable, Sendable {
        /// The host we just installed is the one answering.
        case ready
        /// Something owns :8737, but it isn't ours and it isn't going away.
        case foreign(build: String?)
        /// Nothing answered before the timeout.
        case silent
    }

    /// Wait until the host *we just started* is the one answering.
    ///
    /// A plain 200 proves nothing here. The outgoing process keeps answering
    /// through bootout, so the first poll after a restart routinely describes
    /// the host being replaced. And when a foreign host owns the port — one run
    /// by hand from a clone, or an agent launchd lost track of — ours hits
    /// EADDRINUSE and exits 0 on purpose (see headroom_server.py), leaving the
    /// old one serving while every check says "up".
    ///
    /// With `expecting` nil there is no fingerprint to match — a build with no
    /// bundled host — and any 200 has to do.
    static func waitUntilReady(
        port: Int = defaultPort,
        expecting build: String? = nil,
        attempts: Int = 40
    ) async -> Readiness {
        var lastSeen: HealthReport?
        for _ in 0..<attempts {
            if let report = await probe(port: port) {
                guard let build else { return .ready }
                if report.build == build { return .ready }
                lastSeen = report
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let lastSeen else { return .silent }
        return .foreign(build: lastSeen.build)
    }

    static func uninstall() {
        retireLegacyAgent()
        _ = runLaunchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    /// Drop the pre-rename LaunchAgent so KeepAlive can't bind-fight :8737.
    private static func retireLegacyAgent() {
        _ = runLaunchctl(["bootout", "\(domain)/\(legacyLabel)"])
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
        try? FileManager.default.removeItem(at: legacy)
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
