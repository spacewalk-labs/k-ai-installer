import Foundation

final class HostProber: @unchecked Sendable {
    private let runner: any CommandRunning
    private let resolver: any OrbStackResolving

    init(runner: any CommandRunning, resolver: any OrbStackResolving) {
        self.runner = runner
        self.resolver = resolver
    }

    func probe() throws -> HostProbe {
        let model = try output(
            executable: "/usr/sbin/sysctl",
            arguments: ["-n", "hw.model"],
            operation: "Mac 모델 확인"
        )
        let architecture = try output(
            executable: "/usr/bin/uname",
            arguments: ["-m"],
            operation: "Mac 종류 확인"
        )
        let version = try output(
            executable: "/usr/bin/sw_vers",
            arguments: ["-productVersion"],
            operation: "macOS 버전 확인"
        )
        let build = try output(
            executable: "/usr/bin/sw_vers",
            arguments: ["-buildVersion"],
            operation: "macOS 빌드 확인"
        )
        let freeDiskBytes = try diskFreeBytes()
        let fileVault = try fileVaultStatus()
        let orbStack = orbStackStatus()

        return HostProbe(
            model: model,
            architecture: architecture,
            macOSVersion: version,
            macOSBuild: build,
            freeDiskBytes: freeDiskBytes,
            fileVault: fileVault,
            orbStack: orbStack
        )
    }

    private func output(executable: String, arguments: [String], operation: String) throws -> String {
        let result = try runner.run(CommandRequest(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            operation: operation
        )).checked(operation: operation)
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw SafeInstallerError(.invalidResponse, "Mac 정보를 읽지 못했습니다. 다시 시도해 주세요.")
        }
        return value
    }

    private func diskFreeBytes() throws -> UInt64 {
        let operation = "남은 저장 공간 확인"
        let result = try runner.run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/df"),
            arguments: ["-k", "/System/Volumes/Data"],
            operation: operation
        )).checked(operation: operation)

        let lines = result.stdoutString.split(whereSeparator: \.isNewline)
        guard let dataLine = lines.last else {
            throw SafeInstallerError(.invalidResponse, "남은 저장 공간을 읽지 못했습니다.")
        }
        let fields = dataLine.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 4, let availableKiB = UInt64(fields[3]) else {
            throw SafeInstallerError(.invalidResponse, "남은 저장 공간을 읽지 못했습니다.")
        }
        return availableKiB.multipliedReportingOverflow(by: 1_024).overflow
            ? UInt64.max
            : availableKiB * 1_024
    }

    private func fileVaultStatus() throws -> FileVaultStatus {
        let result = try runner.run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/fdesetup"),
            arguments: ["status"],
            operation: "FileVault 확인"
        ))
        guard result.exitCode == 0 else { return .unknown }
        let status = (result.stdoutString + result.stderrString).lowercased()
        if status.contains("filevault is on") { return .on }
        if status.contains("filevault is off") { return .off }
        return .unknown
    }

    private func orbStackStatus() -> OrbStackProbe {
        do {
            let resolved = try resolver.resolve()
            return OrbStackProbe(installed: true, trusted: true, version: resolved.version)
        } catch let error as SafeInstallerError where error.code == .orbStackUnavailable {
            return OrbStackProbe(installed: false, trusted: false, version: nil)
        } catch {
            return OrbStackProbe(installed: true, trusted: false, version: nil)
        }
    }
}
