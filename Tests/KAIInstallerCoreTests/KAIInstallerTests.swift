import Darwin
import Foundation

private final class KAIInstallerTests {
    private var temporaryDirectoryURL: URL!
    private var stateURL: URL!

    func setUp() throws {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KAIInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)
        stateURL = temporaryDirectoryURL.appendingPathComponent("state/state.json")
    }

    func tearDown() throws {
        if let temporaryDirectoryURL {
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        }
    }

    func testNewInstallCreatesTwoFixedIsolatedMachinesAndSecureState() throws {
        let runner = FakeCommandRunner()
        let installer = makeInstaller(runner: runner)

        let report = try installer.apply(progress: nil)

        XCTAssertTrue(report.verified)
        XCTAssertEqual(report.machines.map(\.name), ["k-ai-dev", "k-ai-runner"])
        XCTAssertEqual(runner.createRequests.count, 2)
        for request in runner.createRequests {
            XCTAssertEqual(Array(request.arguments.prefix(7)), [
                "create", "--isolated", "--isolate-network", "--memory", "2G", "--cpus", "2"
            ])
            XCTAssertTrue(request.arguments.contains("--disk"))
            XCTAssertTrue(request.arguments.contains("24G"))
            XCTAssertTrue(request.arguments.contains("--user-data"))
            XCTAssertTrue(request.arguments.contains("ubuntu:noble"))
        }
        XCTAssertEqual(Set(runner.observedCloudInitModes), [0o600])

        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777, 0o600)
        let stateData = try Data(contentsOf: stateURL)
        let stateText = String(decoding: stateData, as: UTF8.self)
        XCTAssertFalse(stateText.contains(FixedNonceGenerator.value.base64EncodedString()))
        assertNoRealOrbWasRun(runner)
    }

    func testSecondApplyIsIdempotent() throws {
        let runner = FakeCommandRunner()
        let installer = makeInstaller(runner: runner)

        _ = try installer.apply(progress: nil)
        let createCount = runner.createRequests.count
        _ = try installer.apply(progress: nil)

        XCTAssertEqual(runner.createRequests.count, createCount)
        XCTAssertTrue(runner.deleteIdentifiers.isEmpty)
        XCTAssertEqual(runner.machines.count, 2)
        assertNoRealOrbWasRun(runner)
    }

    func testConcurrentInstallerIsRejectedBeforeOrbMutation() throws {
        let runner = FakeCommandRunner()
        let blocker = BlockingFailureInjector(point: .beforeDevelopmentCreate)
        let firstInstaller = makeInstaller(runner: runner, failureInjector: blocker)
        let secondInstaller = makeInstaller(runner: runner)
        let firstFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? firstInstaller.apply(progress: nil)
            firstFinished.signal()
        }

        XCTAssertTrue(blocker.waitUntilHit(), "first installer did not acquire the transaction lock")
        XCTAssertThrowsError(try secondInstaller.apply(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .transactionBusy)
        }
        XCTAssertTrue(runner.createRequests.isEmpty)

        blocker.release()
        XCTAssertTrue(firstFinished.wait(timeout: .now() + 5) == .success)
        XCTAssertEqual(runner.createRequests.compactMap { $0.arguments.last }, ["k-ai-dev", "k-ai-runner"])
        XCTAssertEqual(runner.machines.count, 2)
        assertNoRealOrbWasRun(runner)
    }

    func testUnmarkedSameNameCollisionFailsWithoutCreateOrDelete() throws {
        let runner = FakeCommandRunner()
        runner.addForeignMachine(named: "k-ai-dev", marker: nil)
        let installer = makeInstaller(runner: runner)

        XCTAssertThrowsError(try installer.apply(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .ownershipConflict)
        }

        XCTAssertTrue(runner.createRequests.isEmpty)
        XCTAssertTrue(runner.deleteIdentifiers.isEmpty)
        XCTAssertNotNil(runner.machines["k-ai-dev"])
        assertNoRealOrbWasRun(runner)
    }

    func testPartialInstallResumesAfterDevelopmentOwnershipWithoutDuplicateCreate() throws {
        let runner = FakeCommandRunner()
        let failures = OneShotFailureInjector(point: .afterDevelopmentOwnership)
        let installer = makeInstaller(runner: runner, failureInjector: failures)

        XCTAssertThrowsError(try installer.apply(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .injectedFailure)
        }
        XCTAssertEqual(runner.createRequests.last?.arguments.last, "k-ai-dev")

        let report = try installer.apply(progress: nil)

        XCTAssertTrue(report.verified)
        XCTAssertEqual(runner.createRequests.map { $0.arguments.last! }, ["k-ai-dev", "k-ai-runner"])
        XCTAssertTrue(runner.deleteIdentifiers.isEmpty)
        assertNoRealOrbWasRun(runner)
    }

    func testEveryInjectedFailurePointResumesWithoutDuplicateMutation() throws {
        let points: [FailurePoint] = [
            .beforeDevelopmentCreate,
            .afterDevelopmentCreateBeforeOwnerCheck,
            .afterDevelopmentOwnership,
            .beforeRunnerCreate,
            .afterRunnerCreateBeforeOwnerCheck,
            .afterRunnerOwnership,
            .beforeFinalVerify,
        ]

        for point in points {
            stateURL = temporaryDirectoryURL
                .appendingPathComponent(point.rawValue)
                .appendingPathComponent("state.json")
            let runner = FakeCommandRunner()
            let installer = makeInstaller(
                runner: runner,
                failureInjector: OneShotFailureInjector(point: point)
            )

            XCTAssertThrowsError(try installer.apply(progress: nil)) { error in
                XCTAssertEqual((error as? SafeInstallerError)?.code, .injectedFailure)
            }
            let report = try installer.apply(progress: nil)

            XCTAssertTrue(report.verified, "resume did not verify after \(point.rawValue)")
            XCTAssertEqual(
                runner.createRequests.compactMap { $0.arguments.last },
                ["k-ai-dev", "k-ai-runner"],
                "unexpected create sequence after \(point.rawValue)"
            )
            XCTAssertTrue(runner.deleteIdentifiers.isEmpty, "unexpected delete after \(point.rawValue)")
            XCTAssertEqual(runner.machines.count, 2, "unexpected machine count after \(point.rawValue)")
            assertNoRealOrbWasRun(runner)
        }
    }

    func testCreateChildFailureResumesPendingOwnedRecord() throws {
        let runner = FakeCommandRunner()
        runner.failAfterCreatingName = "k-ai-dev"
        let installer = makeInstaller(runner: runner)

        XCTAssertThrowsError(try installer.apply(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .commandFailed)
        }
        XCTAssertNotNil(runner.machines["k-ai-dev"])

        let report = try installer.apply(progress: nil)

        XCTAssertTrue(report.verified)
        XCTAssertEqual(runner.createRequests.map { $0.arguments.last! }, ["k-ai-dev", "k-ai-runner"])
        XCTAssertTrue(runner.deleteIdentifiers.isEmpty)
        assertNoRealOrbWasRun(runner)
    }

    func testPendingRecordWithoutOwnerMarkerFailsClosedWithoutMutation() throws {
        let runner = FakeCommandRunner()
        let installer = makeInstaller(
            runner: runner,
            failureInjector: OneShotFailureInjector(point: .beforeDevelopmentCreate)
        )
        XCTAssertThrowsError(try installer.apply(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .injectedFailure)
        }
        runner.addForeignMachine(named: "k-ai-dev", marker: nil)

        XCTAssertThrowsError(try installer.apply(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .ownershipConflict)
        }

        XCTAssertTrue(runner.createRequests.isEmpty)
        XCTAssertTrue(runner.deleteIdentifiers.isEmpty)
        XCTAssertNotNil(runner.machines["k-ai-dev"])
        assertNoRealOrbWasRun(runner)
    }

    func testCorruptStateFailsClosedWithoutOrbMutation() throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{truncated".utf8).write(to: stateURL)
        let runner = FakeCommandRunner()
        let installer = makeInstaller(runner: runner)

        XCTAssertThrowsError(try installer.apply(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .stateCorrupt)
        }

        XCTAssertTrue(runner.createRequests.isEmpty)
        XCTAssertTrue(runner.deleteIdentifiers.isEmpty)
        assertNoRealOrbWasRun(runner)
    }

    func testFutureStateSchemaFailsClosedWithoutOrbMutation() throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let futureState = """
        {"schemaVersion":999,"installID":"future","ownerNonceHash":"\(String(repeating: "0", count: 64))","machines":[],"lastVerificationSucceeded":false}
        """
        try Data(futureState.utf8).write(to: stateURL)
        let runner = FakeCommandRunner()
        let installer = makeInstaller(runner: runner)

        XCTAssertThrowsError(try installer.apply(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .stateCorrupt)
        }

        XCTAssertTrue(runner.createRequests.isEmpty)
        XCTAssertTrue(runner.deleteIdentifiers.isEmpty)
        assertNoRealOrbWasRun(runner)
    }

    func testSchemaOneStateWithoutDeletionJournalRemainsReadable() throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacyState = """
        {"schemaVersion":1,"installID":"legacy","ownerNonceHash":"\(String(repeating: "0", count: 64))","machines":[],"lastVerificationSucceeded":false}
        """
        try Data(legacyState.utf8).write(to: stateURL)

        let loaded = try JSONInstallerStateStore(stateURL: stateURL).load()

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.installID, "legacy")
        XCTAssertEqual(loaded?.pendingDeletion, nil)
    }

    func testRollbackWrongOwnerRefusesBeforeAnyDelete() throws {
        let runner = FakeCommandRunner()
        let installer = makeInstaller(runner: runner)
        _ = try installer.apply(progress: nil)
        runner.replaceMarker(
            named: "k-ai-dev",
            with: OwnerMarker(installID: "foreign-install", ownerNonce: Data(repeating: 9, count: 32).base64EncodedString())
        )

        XCTAssertThrowsError(try installer.rollback(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .rollbackRefused)
        }

        XCTAssertTrue(runner.deleteIdentifiers.isEmpty)
        XCTAssertEqual(runner.machines.count, 2)
        assertNoRealOrbWasRun(runner)
    }

    func testRollbackDeletesOnlyOwnedRecordIDsAndState() throws {
        let runner = FakeCommandRunner()
        runner.addForeignMachine(named: "unrelated", marker: nil)
        let installer = makeInstaller(runner: runner)
        _ = try installer.apply(progress: nil)
        let ownedIDs = Set(runner.machines.values.filter { $0.name.hasPrefix("k-ai-") }.map(\.id))
        try installer.rollback(progress: nil)

        XCTAssertEqual(Set(runner.deleteIdentifiers), ownedIDs)
        XCTAssertTrue(runner.requests.filter { $0.arguments.first == "delete" }.allSatisfy {
            $0.arguments.dropLast() == ["delete", "--force"]
        })
        XCTAssertNotNil(runner.machines["unrelated"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        assertNoRealOrbWasRun(runner)
    }

    func testRollbackDeleteSuccessWithoutRemovalPreservesState() throws {
        let runner = FakeCommandRunner()
        let installer = makeInstaller(runner: runner)
        _ = try installer.apply(progress: nil)
        runner.deleteSucceedsWithoutRemoving = true

        XCTAssertThrowsError(try installer.rollback(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .verificationFailed)
        }

        XCTAssertEqual(runner.deleteIdentifiers.count, 1)
        XCTAssertEqual(runner.machines.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        let diagnosticsURL = temporaryDirectoryURL.appendingPathComponent("no-op-diagnostics.json")
        try installer.writeSupportDiagnostics(to: diagnosticsURL)
        let diagnostics = try JSONDecoder().decode(
            SupportDiagnostics.self,
            from: Data(contentsOf: diagnosticsURL)
        )
        XCTAssertTrue(diagnostics.recoveryPending)
        XCTAssertEqual(diagnostics.recordedMachineNames, ["k-ai-dev", "k-ai-runner"])
        let diagnosticsText = String(decoding: try Data(contentsOf: diagnosticsURL), as: UTF8.self)
        XCTAssertFalse(diagnosticsText.contains("install-test-001"))
        XCTAssertFalse(diagnosticsText.contains("record-"))
        XCTAssertFalse(diagnosticsText.contains(FixedNonceGenerator.value.base64EncodedString()))

        runner.deleteSucceedsWithoutRemoving = false
        try installer.rollback(progress: nil)

        XCTAssertEqual(runner.deleteIdentifiers.count, 3)
        XCTAssertTrue(runner.machines.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        assertNoRealOrbWasRun(runner)
    }

    func testRollbackCommandFailureStillWritesRedactedDiagnostics() throws {
        let runner = FakeCommandRunner()
        let installer = makeInstaller(runner: runner)
        _ = try installer.apply(progress: nil)
        runner.deleteFailureExitCode = 2

        XCTAssertThrowsError(try installer.rollback(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .commandFailed)
        }

        let outputURL = temporaryDirectoryURL.appendingPathComponent("failed-rollback-diagnostics.json")
        try installer.writeSupportDiagnostics(to: outputURL)
        let data = try Data(contentsOf: outputURL)
        let diagnostics = try JSONDecoder().decode(SupportDiagnostics.self, from: data)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(diagnostics.recoveryPending)
        XCTAssertEqual(diagnostics.recordedMachineNames, ["k-ai-dev", "k-ai-runner"])
        XCTAssertFalse(text.contains("install-test-001"))
        XCTAssertFalse(text.contains("record-"))
        XCTAssertFalse(text.contains(FixedNonceGenerator.value.base64EncodedString()))
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777, 0o600)
        assertNoRealOrbWasRun(runner)
    }

    func testRollbackResumesAfterDeleteBeforeStateUpdate() throws {
        let runner = FakeCommandRunner()
        let installer = makeInstaller(
            runner: runner,
            failureInjector: OneShotFailureInjector(point: .afterRollbackDeleteBeforeState)
        )
        _ = try installer.apply(progress: nil)

        XCTAssertThrowsError(try installer.rollback(progress: nil)) { error in
            XCTAssertEqual((error as? SafeInstallerError)?.code, .injectedFailure)
        }
        XCTAssertEqual(runner.machines.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))

        try installer.rollback(progress: nil)

        XCTAssertTrue(runner.machines.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        assertNoRealOrbWasRun(runner)
    }

    func testCommandErrorDoesNotExposeCapturedOutput() throws {
        let runner = FakeCommandRunner()
        runner.forcedInfoError = "BWS_ACCESS_TOKEN=must-not-leak /Users/private"
        let installer = makeInstaller(runner: runner)

        XCTAssertThrowsError(try installer.apply(progress: nil)) { error in
            let safe = error as? SafeInstallerError
            XCTAssertEqual(safe?.code, .commandFailed)
            XCTAssertFalse(safe?.message.contains("BWS_ACCESS_TOKEN") ?? true)
            XCTAssertFalse(safe?.message.contains("/Users/private") ?? true)
        }
        assertNoRealOrbWasRun(runner)
    }

    func testSupportDiagnosticsOmitsOwnershipIdentifiersAndUsesSecureMode() throws {
        let runner = FakeCommandRunner()
        let installer = makeInstaller(runner: runner)
        _ = try installer.apply(progress: nil)
        let outputURL = temporaryDirectoryURL.appendingPathComponent("support-diagnostics.json")

        try installer.writeSupportDiagnostics(to: outputURL)

        let text = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        XCTAssertTrue(text.contains("k-ai-dev"))
        XCTAssertTrue(text.contains("k-ai-runner"))
        XCTAssertFalse(text.contains("install-test-001"))
        XCTAssertFalse(text.contains("record-1"))
        XCTAssertFalse(text.contains(FixedNonceGenerator.value.base64EncodedString()))
        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777, 0o600)
        assertNoRealOrbWasRun(runner)
    }

    func testNotarizedResolverPrefersAppInternalBinaryAndChecksIdentity() throws {
        let bundleURL = temporaryDirectoryURL.appendingPathComponent("OrbStack.app")
        let executableURL = bundleURL.appendingPathComponent("Contents/MacOS/bin/orb")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: executableURL.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        let fallbackURL = temporaryDirectoryURL.appendingPathComponent("fallback/orb")
        let runner = FakeCommandRunner()
        let resolver = NotarizedOrbStackResolver(
            runner: runner,
            candidates: [executableURL, fallbackURL],
            bundleURL: bundleURL,
            fileManager: .default
        )

        let result = try resolver.resolve()

        XCTAssertEqual(result.executableURL, executableURL)
        XCTAssertEqual(result.version, "2.2.1")
        XCTAssertTrue(runner.requests.contains { $0.executableURL.path == "/usr/sbin/spctl" })
        XCTAssertTrue(runner.requests.contains { $0.executableURL.path == "/usr/bin/codesign" })
        XCTAssertTrue(runner.requests.contains { $0.executableURL == executableURL && $0.arguments == ["version"] })
    }

    private func makeInstaller(
        runner: FakeCommandRunner,
        failureInjector: any FailureInjecting = NoFailureInjector()
    ) -> KAIInstaller {
        KAIInstaller(
            runner: runner,
            resolver: FixedOrbStackResolver(),
            stateStore: JSONInstallerStateStore(stateURL: stateURL),
            nonceGenerator: FixedNonceGenerator(),
            installIDGenerator: FixedInstallIDGenerator(),
            failureInjector: failureInjector,
            sleeper: NoopInstallerSleeper(),
            temporaryDirectoryURL: temporaryDirectoryURL
        )
    }

    private func assertNoRealOrbWasRun(_ runner: FakeCommandRunner, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            runner.requests.contains { $0.executableURL.path != FakeCommandRunner.orbPath && $0.executableURL.lastPathComponent == "orb" },
            "A test attempted to execute a non-fake orb binary",
            file: file,
            line: line
        )
    }
}

private struct RecordedFailure: Sendable {
    let message: String
    let file: String
    let line: UInt
}

private final class TestRecorder: @unchecked Sendable {
    static let shared = TestRecorder()
    var failures: [RecordedFailure] = []

    func record(_ message: String, file: StaticString, line: UInt) {
        failures.append(RecordedFailure(message: message, file: "\(file)", line: line))
    }
}

private func XCTAssertTrue(
    _ expression: @autoclosure () -> Bool,
    _ message: String = "expected true",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if !expression() { TestRecorder.shared.record(message, file: file, line: line) }
}

private func XCTAssertFalse(
    _ expression: @autoclosure () -> Bool,
    _ message: String = "expected false",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if expression() { TestRecorder.shared.record(message, file: file, line: line) }
}

private func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () -> T,
    _ expression2: @autoclosure () -> T,
    _ message: String = "values are not equal",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if expression1() != expression2() { TestRecorder.shared.record(message, file: file, line: line) }
}

private func XCTAssertNotNil<T>(
    _ expression: @autoclosure () -> T?,
    _ message: String = "value is nil",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if expression() == nil { TestRecorder.shared.record(message, file: file, line: line) }
}

private func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) {
    do {
        _ = try expression()
        TestRecorder.shared.record("expected an error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

@main
private enum KAIInstallerSelfTest {
    static func main() {
        let cases: [(String, (KAIInstallerTests) throws -> Void)] = [
            ("new install", { try $0.testNewInstallCreatesTwoFixedIsolatedMachinesAndSecureState() }),
            ("idempotent apply", { try $0.testSecondApplyIsIdempotent() }),
            ("concurrent installer lock", { try $0.testConcurrentInstallerIsRejectedBeforeOrbMutation() }),
            ("foreign collision", { try $0.testUnmarkedSameNameCollisionFailsWithoutCreateOrDelete() }),
            ("resume after ownership", { try $0.testPartialInstallResumesAfterDevelopmentOwnershipWithoutDuplicateCreate() }),
            ("all injected failure points", { try $0.testEveryInjectedFailurePointResumesWithoutDuplicateMutation() }),
            ("resume after child failure", { try $0.testCreateChildFailureResumesPendingOwnedRecord() }),
            ("pending unmarked record", { try $0.testPendingRecordWithoutOwnerMarkerFailsClosedWithoutMutation() }),
            ("corrupt state", { try $0.testCorruptStateFailsClosedWithoutOrbMutation() }),
            ("future state schema", { try $0.testFutureStateSchemaFailsClosedWithoutOrbMutation() }),
            ("schema one compatibility", { try $0.testSchemaOneStateWithoutDeletionJournalRemainsReadable() }),
            ("wrong owner rollback", { try $0.testRollbackWrongOwnerRefusesBeforeAnyDelete() }),
            ("owned rollback", { try $0.testRollbackDeletesOnlyOwnedRecordIDsAndState() }),
            ("rollback delete no-op", { try $0.testRollbackDeleteSuccessWithoutRemovalPreservesState() }),
            ("rollback failure diagnostics", { try $0.testRollbackCommandFailureStillWritesRedactedDiagnostics() }),
            ("rollback journal resume", { try $0.testRollbackResumesAfterDeleteBeforeStateUpdate() }),
            ("redacted command error", { try $0.testCommandErrorDoesNotExposeCapturedOutput() }),
            ("redacted support diagnostics", { try $0.testSupportDiagnosticsOmitsOwnershipIdentifiersAndUsesSecureMode() }),
            ("trusted resolver", { try $0.testNotarizedResolverPrefersAppInternalBinaryAndChecksIdentity() }),
        ]

        var failedCases = 0
        for (name, body) in cases {
            let test = KAIInstallerTests()
            let initialFailureCount = TestRecorder.shared.failures.count
            do {
                try test.setUp()
                try body(test)
                try test.tearDown()
            } catch {
                TestRecorder.shared.record("unexpected error: \(error)", file: #filePath, line: #line)
                try? test.tearDown()
            }

            if TestRecorder.shared.failures.count == initialFailureCount {
                print("PASS: \(name)")
            } else {
                failedCases += 1
                print("FAIL: \(name)")
            }
        }

        for failure in TestRecorder.shared.failures {
            fputs("\(failure.file):\(failure.line): \(failure.message)\n", stderr)
        }
        print("Self-test: \(cases.count - failedCases) passed, \(failedCases) failed")
        exit(failedCases == 0 ? 0 : 1)
    }
}

private struct FixedOrbStackResolver: OrbStackResolving {
    func resolve() throws -> ResolvedOrbStack {
        ResolvedOrbStack(executableURL: URL(fileURLWithPath: FakeCommandRunner.orbPath), version: "2.2.1")
    }
}

private struct FixedNonceGenerator: NonceGenerating {
    static let value = Data((0..<32).map(UInt8.init))
    func generate() throws -> Data { Self.value }
}

private struct FixedInstallIDGenerator: InstallIDGenerating {
    func generate() -> String { "install-test-001" }
}

private struct NoopInstallerSleeper: InstallerSleeping {
    func sleepForOwnerMarkerAttempt() {}
}

private final class OneShotFailureInjector: FailureInjecting, @unchecked Sendable {
    private let point: FailurePoint
    private var hasFailed = false

    init(point: FailurePoint) {
        self.point = point
    }

    func hit(_ point: FailurePoint) throws {
        guard point == self.point, !hasFailed else { return }
        hasFailed = true
        throw SafeInstallerError(.injectedFailure, "테스트 실패 지점")
    }
}

private final class BlockingFailureInjector: FailureInjecting, @unchecked Sendable {
    private let point: FailurePoint
    private let reached = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    init(point: FailurePoint) {
        self.point = point
    }

    func hit(_ point: FailurePoint) throws {
        guard point == self.point else { return }
        reached.signal()
        resume.wait()
    }

    func waitUntilHit() -> Bool {
        reached.wait(timeout: .now() + 5) == .success
    }

    func release() {
        resume.signal()
    }
}

private final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    static let orbPath = "/fake/orb"

    struct Machine {
        let id: String
        let name: String
        var marker: OwnerMarker?
        let isolated: Bool
        let isolateNetwork: Bool
        let forwardSSHAgent: Bool
        let memoryMiB: Int
        let cpuCount: Int
        let diskBytes: UInt64
    }

    var requests: [CommandRequest] = []
    var machines: [String: Machine] = [:]
    var observedCloudInitModes: [Int] = []
    var deleteIdentifiers: [String] = []
    var deleteSucceedsWithoutRemoving = false
    var deleteFailureExitCode: Int32?
    var failAfterCreatingName: String?
    var forcedInfoError: String?
    private var nextRecordNumber = 1

    var createRequests: [CommandRequest] {
        requests.filter { $0.executableURL.path == Self.orbPath && $0.arguments.first == "create" }
    }

    func run(_ request: CommandRequest) throws -> CommandResult {
        requests.append(request)

        switch request.executableURL.path {
        case "/usr/sbin/sysctl":
            return CommandResult(exitCode: 0, stdout: "Mac14,3\n")
        case "/usr/bin/uname":
            return CommandResult(exitCode: 0, stdout: "arm64\n")
        case "/usr/bin/sw_vers":
            return CommandResult(exitCode: 0, stdout: request.arguments == ["-productVersion"] ? "15.1.1\n" : "24B91\n")
        case "/bin/df":
            return CommandResult(exitCode: 0, stdout: "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/test 500000000 1 200000000 1% /System/Volumes/Data\n")
        case "/usr/bin/fdesetup":
            return CommandResult(exitCode: 0, stdout: "FileVault is Off.\n")
        case "/usr/sbin/spctl":
            return CommandResult(exitCode: 0, stdout: "accepted\nsource=Notarized Developer ID\n")
        case "/usr/bin/codesign":
            return CommandResult(
                exitCode: 0,
                stdout: "",
                stderr: "Identifier=dev.kdrag0n.MacVirt\nTeamIdentifier=HUAQ24HBR6\n"
            )
        default:
            if request.arguments == ["version"] {
                return CommandResult(exitCode: 0, stdout: "orb version 2.2.1\n")
            }
            guard request.executableURL.path == Self.orbPath else {
                return CommandResult(exitCode: 127, stdout: "", stderr: "unexpected executable")
            }
            return try runOrb(request)
        }
    }

    func addForeignMachine(named name: String, marker: OwnerMarker?) {
        machines[name] = Machine(
            id: "foreign-\(name)",
            name: name,
            marker: marker,
            isolated: true,
            isolateNetwork: true,
            forwardSSHAgent: false,
            memoryMiB: 2_048,
            cpuCount: 2,
            diskBytes: 24 * 1_024 * 1_024 * 1_024
        )
    }

    func replaceMarker(named name: String, with marker: OwnerMarker?) {
        guard var machine = machines[name] else { return }
        machine.marker = marker
        machines[name] = machine
    }

    private func runOrb(_ request: CommandRequest) throws -> CommandResult {
        switch request.arguments.first {
        case "info":
            if let forcedInfoError {
                return CommandResult(exitCode: 2, stdout: "", stderr: forcedInfoError)
            }
            guard let identifier = request.arguments.last,
                  let machine = machine(identifier: identifier)
            else {
                return CommandResult(exitCode: 1, stdout: "", stderr: "[-32098] machine not found: 'fixture'\n")
            }
            let object: [String: Any] = [
                "record": [
                    "id": machine.id,
                    "name": machine.name,
                    "image": ["distro": "ubuntu", "version": "noble", "arch": "arm64"],
                    "config": [
                        "isolated": machine.isolated,
                        "isolate_network": machine.isolateNetwork,
                        "forward_ssh_agent": machine.forwardSSHAgent,
                        "memory_limit_mib": machine.memoryMiB
                    ],
                    "state": "running"
                ]
            ]
            return CommandResult(exitCode: 0, standardOutput: try JSONSerialization.data(withJSONObject: object))

        case "create":
            guard let name = request.arguments.last,
                  let cloudInitFlag = request.arguments.firstIndex(of: "--user-data"),
                  request.arguments.indices.contains(cloudInitFlag + 1)
            else {
                return CommandResult(exitCode: 2, stdout: "", stderr: "bad create request")
            }
            let cloudInitURL = URL(fileURLWithPath: request.arguments[cloudInitFlag + 1])
            let attributes = try FileManager.default.attributesOfItem(atPath: cloudInitURL.path)
            observedCloudInitModes.append((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1)
            let marker = try decodeMarker(fromCloudInitAt: cloudInitURL)
            let machine = Machine(
                id: "record-\(nextRecordNumber)",
                name: name,
                marker: marker,
                isolated: request.arguments.contains("--isolated"),
                isolateNetwork: request.arguments.contains("--isolate-network"),
                forwardSSHAgent: false,
                memoryMiB: 2_048,
                cpuCount: 2,
                diskBytes: 24 * 1_024 * 1_024 * 1_024
            )
            nextRecordNumber += 1
            machines[name] = machine
            if failAfterCreatingName == name {
                failAfterCreatingName = nil
                throw SafeInstallerError.commandFailed(operation: request.operation, exitCode: 1)
            }
            return CommandResult(exitCode: 0, stdout: "created\n")

        case "run":
            guard let machineFlag = request.arguments.firstIndex(of: "-m"),
                  request.arguments.indices.contains(machineFlag + 1),
                  let machine = machines[request.arguments[machineFlag + 1]],
                  let marker = machine.marker
            else {
                return CommandResult(exitCode: 1, stdout: "", stderr: "owner marker unavailable")
            }
            return CommandResult(exitCode: 0, standardOutput: try JSONEncoder().encode(marker))

        case "delete":
            guard request.arguments.count == 3, request.arguments[1] == "--force" else {
                return CommandResult(exitCode: 2, stdout: "", stderr: "bad delete request")
            }
            let identifier = request.arguments[2]
            deleteIdentifiers.append(identifier)
            if let deleteFailureExitCode {
                return CommandResult(exitCode: deleteFailureExitCode, stdout: "", stderr: "delete failed")
            }
            if deleteSucceedsWithoutRemoving {
                return CommandResult(exitCode: 0, stdout: "accepted\n")
            }
            if let machine = machine(identifier: identifier) {
                machines.removeValue(forKey: machine.name)
                return CommandResult(exitCode: 0, stdout: "deleted\n")
            }
            return CommandResult(exitCode: 1, stdout: "", stderr: "not found")

        case "config":
            guard request.arguments.count == 3,
                  request.arguments[1] == "get"
            else {
                return CommandResult(exitCode: 2, stdout: "", stderr: "bad config request")
            }
            let components = request.arguments[2].split(separator: ".")
            guard components.count == 3,
                  let machine = machines[String(components[1])]
            else {
                return CommandResult(exitCode: 1, stdout: "", stderr: "unknown machine")
            }
            switch components.last {
            case "cpu":
                return CommandResult(exitCode: 0, stdout: "\(machine.cpuCount)\n")
            case "disk_bytes":
                return CommandResult(exitCode: 0, stdout: "\(machine.diskBytes)\n")
            default:
                return CommandResult(exitCode: 1, stdout: "", stderr: "unknown key")
            }

        default:
            return CommandResult(exitCode: 2, stdout: "", stderr: "unexpected orb command")
        }
    }

    private func machine(identifier: String) -> Machine? {
        machines[identifier] ?? machines.values.first(where: { $0.id == identifier })
    }

    private func decodeMarker(fromCloudInitAt url: URL) throws -> OwnerMarker {
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("content:") }),
              let encoded = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces),
              let data = Data(base64Encoded: encoded)
        else {
            throw SafeInstallerError(.invalidResponse, "invalid test cloud-init")
        }
        return try JSONDecoder().decode(OwnerMarker.self, from: data)
    }
}
