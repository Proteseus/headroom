import CryptoKit
import Foundation
import SwiftUI

/// The Swift half of the host version handshake. Mirrors host/host_version.py.
///
/// The app bundles a copy of the Python host and installs a LaunchAgent pointing
/// at it. launchd keeps whatever it was given alive across app updates, so the
/// running host can easily be a build the app has never seen — from an older
/// .app, or from a clone via scripts/install-host.sh. Nothing failed loudly when
/// that happened: the app just decoded keys the old host doesn't emit and drew
/// blanks.
///
/// So the app fingerprints the copy it ships and compares it against what
/// /health reports. The rule is a cross-language contract, spelled out in
/// host_version.py and pinned on both sides by the same golden vector
/// (host/test_host_version.py, Tests/HostVersionTests.swift):
///
///   files   entries directly in the directory (no recursion) named VERSION, or
///           ending in .py and not starting with test_
///   order   sorted by name, byte-wise
///   digest  sha256 over, per file: name + "\n" + byte-length + "\n" + bytes + "\n"
///   result  first 12 hex characters
enum HostVersion {
    static let fallbackVersion = "0.0.0"

    /// The release line from the VERSION file, or nil when there isn't one.
    static func version(in directory: URL) -> String? {
        let url = directory.appendingPathComponent("VERSION")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Does this name count toward the fingerprint? The one place that rule
    /// lives on this side — the staleness check reuses it to decide which
    /// files it has to watch.
    static func isShipped(_ name: String) -> Bool {
        if name == "VERSION" { return true }
        return name.hasSuffix(".py") && !name.hasPrefix("test_")
    }

    /// The files that define a build: flat, no tests, no __pycache__.
    static func shippedFiles(in directory: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let kept = names.filter { name in
            var isDir: ObjCBool = false
            let path = directory.appendingPathComponent(name).path
            guard fm.fileExists(atPath: path, isDirectory: &isDir),
                  !isDir.boolValue else { return false }
            return isShipped(name)
        }
        // Byte-wise, to match Python's sort. Swift's default String `<` is
        // Unicode-canonical and would order differently for non-ASCII names.
        return kept.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// Short fingerprint of a host directory. See the type docs for the rule.
    static func build(in directory: URL) -> String? {
        var digest = SHA256()
        var hashedAnything = false
        for name in shippedFiles(in: directory) {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            digest.update(data: Data(name.utf8))
            digest.update(data: Data("\n".utf8))
            digest.update(data: Data(String(data.count).utf8))
            digest.update(data: Data("\n".utf8))
            digest.update(data: data)
            digest.update(data: Data("\n".utf8))
            hashedAnything = true
        }
        guard hashedAnything else { return nil }
        let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    /// Cheap stand-in for the contents of a host directory: every shipped file's
    /// name, size and mtime. Two identical stamps mean the digest would come out
    /// identical too, so it can be cached against this instead of recomputed —
    /// and a directory rewritten underneath a running process changes it.
    ///
    /// Not the directory's own mtime: overwriting a file in place leaves that
    /// untouched, which is exactly how a build lands on top of a running app.
    static func stamp(of directory: URL) -> String {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .isDirectoryKey,
        ]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants]
        ) else { return "" }
        var parts: [String] = []
        for url in entries {
            let name = url.lastPathComponent
            guard isShipped(name) else { continue }
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isDirectory != true else { continue }
            let size = values?.fileSize ?? -1
            let modified = values?.contentModificationDate?
                .timeIntervalSince1970 ?? -1
            parts.append("\(name):\(size):\(modified)")
        }
        return parts.sorted().joined(separator: "|")
    }

    /// True when `candidate` is a strictly newer release line than `reference`.
    ///
    /// nil when either side isn't dotted-numeric. Guessing the direction of a
    /// downgrade is worse than declining to offer one — see `HostSkew`.
    static func isNewer(_ candidate: String, than reference: String) -> Bool? {
        guard let left = numericComponents(candidate),
              let right = numericComponents(reference) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            values.append(value)
        }
        return values
    }
}

/// A running host that isn't the one this app ships.
struct HostSkew: Equatable, Sendable {
    /// nil when the host predates the handshake — which is itself proof it's old.
    var runningVersion: String?
    var runningBuild: String?
    var bundledVersion: String
    var bundledBuild: String
    /// The running host reports a newer release line than this .app carries, so
    /// the stale half is the app. Replacing the host would be a downgrade, and
    /// nothing the app installs can fix it — only a newer .app can.
    var hostIsNewer = false

    var runningLabel: String {
        guard let runningVersion else { return "pre-1.0" }
        guard let runningBuild else { return runningVersion }
        return "\(runningVersion) (\(runningBuild))"
    }

    var bundledLabel: String { "\(bundledVersion) (\(bundledBuild))" }

    var summary: String {
        "Running \(runningLabel) · this app ships \(bundledLabel)"
    }

    var title: String {
        hostIsNewer ? "Headroom is out of date" : "Host is out of date"
    }
}

/// Shown in the popover when launchd is serving a host this app didn't ship.
///
/// The store reinstalls on sight (see `installBundledHost`), so by the time
/// anyone reads this banner the automatic attempt is either in flight or it
/// didn't take — a clone's LaunchAgent that keeps winning :8737, a launchctl
/// that refused. The button is the manual retry for that case, not the only
/// way out of skew.
///
/// When the running host is the *newer* half there is no button: installing
/// this app's copy over it is a downgrade, and the app is what needs replacing.
struct HostSkewBanner: View {
    let skew: HostSkew
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(HeadroomPalette.amber)
                Text(skew.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text(skew.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if skew.hostIsNewer {
                Text("Quit and reopen Headroom, or install the matching build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 8) {
                    Button {
                        Task { await store.updateHost() }
                    } label: {
                        if store.isUpdatingHost {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Update host")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.isUpdatingHost)
                    Spacer()
                }
            }
        }
        .cardStyle()
    }
}
