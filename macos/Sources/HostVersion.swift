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
            if name == "VERSION" { return true }
            return name.hasSuffix(".py") && !name.hasPrefix("test_")
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
}

/// A running host that isn't the one this app ships.
struct HostSkew: Equatable, Sendable {
    /// nil when the host predates the handshake — which is itself proof it's old.
    var runningVersion: String?
    var runningBuild: String?
    var bundledVersion: String
    var bundledBuild: String

    var runningLabel: String {
        guard let runningVersion else { return "pre-1.0" }
        guard let runningBuild else { return runningVersion }
        return "\(runningVersion) (\(runningBuild))"
    }

    var bundledLabel: String { "\(bundledVersion) (\(bundledBuild))" }

    var summary: String {
        "Running \(runningLabel) · this app ships \(bundledLabel)"
    }
}

/// Shown in the popover when launchd is serving a host this app didn't ship.
///
/// The store reinstalls on sight (see `installBundledHost`), so by the time
/// anyone reads this banner the automatic attempt is either in flight or it
/// didn't take — a clone's LaunchAgent that keeps winning :8737, a launchctl
/// that refused. The button is the manual retry for that case, not the only
/// way out of skew.
struct HostSkewBanner: View {
    let skew: HostSkew
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(HeadroomPalette.amber)
                Text("Host is out of date")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text(skew.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        .cardStyle()
    }
}
