import XCTest
@testable import Headroom

/// The Swift half of the host version handshake. The Python half is
/// host/test_host_version.py and pins the same GOLDEN_BUILD over the same
/// synthetic tree. If these two constants ever disagree, the app is either
/// nagging about skew that doesn't exist or — worse — reporting "up to date"
/// while launchd serves an older host.
final class HostVersionTests: XCTestCase {

    /// Same constant as GOLDEN_BUILD in host/test_host_version.py.
    private let goldenBuild = "bc208b82c08c"

    /// A host directory in miniature: a version, two modules, and two decoys.
    private func makeGoldenTree() throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("headroom-hostversion-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        let files = [
            "VERSION": "9.9.9\n",
            "alpha.py": "print('a')\n",
            "zeta.py": "print('z')\n",
            // Neither of these ships inside the .app, so neither may move the hash.
            "test_alpha.py": "ignored\n",
            "notes.md": "ignored\n",
        ]
        for (name, body) in files {
            try body.write(
                to: root.appendingPathComponent(name),
                atomically: true, encoding: .utf8)
        }
        let cache = root.appendingPathComponent("__pycache__")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try "ignored\n".write(
            to: cache.appendingPathComponent("alpha.pyc"),
            atomically: true, encoding: .utf8)
        return root
    }

    func testGoldenBuildMatchesThePythonConstant() throws {
        let root = try makeGoldenTree()
        XCTAssertEqual(HostVersion.build(in: root), goldenBuild)
    }

    func testShippedFilesExcludeTestsAndCaches() throws {
        let root = try makeGoldenTree()
        XCTAssertEqual(
            HostVersion.shippedFiles(in: root),
            ["VERSION", "alpha.py", "zeta.py"])
    }

    func testVersionReadsTheVersionFile() throws {
        let root = try makeGoldenTree()
        XCTAssertEqual(HostVersion.version(in: root), "9.9.9")
    }

    func testEditingAModuleMovesTheBuild() throws {
        let root = try makeGoldenTree()
        let before = HostVersion.build(in: root)
        try "print('a2')\n".write(
            to: root.appendingPathComponent("alpha.py"),
            atomically: true, encoding: .utf8)
        XCTAssertNotEqual(HostVersion.build(in: root), before)
    }

    func testEmptyDirectoryHasNoBuild() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("headroom-empty-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(HostVersion.build(in: root))
        XCTAssertNil(HostVersion.version(in: root))
    }

    /// The repo's own host directory, which is what ships. Skipped when the test
    /// bundle can't see the checkout (CI running against a built .app).
    func testCheckoutHostFingerprintsCleanly() throws {
        let hostDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("host")
        try XCTSkipUnless(
            FileManager.default.fileExists(
                atPath: hostDir.appendingPathComponent("VERSION").path),
            "host/VERSION not found at \(hostDir.path)")

        let version = try XCTUnwrap(HostVersion.version(in: hostDir))
        XCTAssertNotNil(
            version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression),
            "VERSION should be a semver, got \(version)")
        let build = try XCTUnwrap(HostVersion.build(in: hostDir))
        XCTAssertEqual(build.count, 12)
        XCTAssertFalse(
            HostVersion.shippedFiles(in: hostDir).contains {
                $0.hasPrefix("test_")
            },
            "test modules must not affect the shipped fingerprint")
    }
}

final class HostSkewTests: XCTestCase {

    private func report(version: String?, build: String?) -> HealthReport {
        HealthReport(
            ok: true, uptimeS: 1, updated: nil, sources: [:],
            version: version, build: build)
    }

    /// A host that answers /health without a build is older than the handshake,
    /// which is exactly the case this whole mechanism exists to catch.
    func testMissingBuildReadsAsSkewWhenBundled() throws {
        try XCTSkipUnless(
            HostController.bundledBuild != nil,
            "no bundled host in this build")
        let skew = try XCTUnwrap(
            HostController.skew(against: report(version: nil, build: nil)))
        XCTAssertNil(skew.runningVersion)
        XCTAssertEqual(skew.runningLabel, "pre-1.0")
    }

    func testMatchingBuildIsNotSkew() throws {
        // Bundle.main is the test runner, not the .app, so a bundled host is
        // only visible when the tests are hosted by Headroom.
        try XCTSkipIf(HostController.bundledBuild == nil, "no bundled host")
        let bundled = try XCTUnwrap(HostController.bundledBuild)
        XCTAssertNil(
            HostController.skew(
                against: report(version: HostController.bundledVersion,
                                build: bundled)))
    }

    func testSummaryNamesBothSides() {
        let skew = HostSkew(
            runningVersion: "1.0.0", runningBuild: "aaaaaaaaaaaa",
            bundledVersion: "1.1.0", bundledBuild: "bbbbbbbbbbbb")
        XCTAssertEqual(
            skew.summary,
            "Running 1.0.0 (aaaaaaaaaaaa) · this app ships 1.1.0 (bbbbbbbbbbbb)")
    }
}
