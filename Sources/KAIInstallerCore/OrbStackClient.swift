import Darwin
import Foundation

struct OwnerMarker: Codable, Equatable, Sendable {
    let installID: String
    let ownerNonce: String
}

struct OrbMachineRecord: Equatable, Sendable {
    let id: String
    let name: String
    let distro: String
    let version: String
    let architecture: String
    let isolated: Bool?
    let isolateNetwork: Bool?
    let forwardSSHAgent: Bool?
    let memoryLimitMiB: Int?
    let cpuCount: Int
    let diskBytes: UInt64
    let state: String
}

private struct OrbInfoEnvelope: Decodable {
    let record: Record

    struct Record: Decodable {
        let id: String
        let name: String
        let image: Image
        let config: Configuration
        let state: String
    }

    struct Image: Decodable {
        let distro: String
        let version: String
        let arch: String
    }

    struct Configuration: Decodable {
        let isolated: Bool?
        let isolateNetwork: Bool?
        let forwardSSHAgent: Bool?
        let memoryLimitMiB: Int?

        enum CodingKeys: String, CodingKey {
            case isolated
            case isolateNetwork = "isolate_network"
            case forwardSSHAgent = "forward_ssh_agent"
            case memoryLimitMiB = "memory_limit_mib"
        }
    }
}

final class OrbStackClient: @unchecked Sendable {
    private static let ownerPath = "/etc/k-ai-installer/owner.json"

    private let runner: any CommandRunning
    private let executableURL: URL
    private let temporaryDirectoryURL: URL

    init(
        runner: any CommandRunning,
        executableURL: URL,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory
    ) {
        self.runner = runner
        self.executableURL = executableURL
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    func machine(named name: String) throws -> OrbMachineRecord? {
        try machine(identifier: name)
    }

    func machine(recordID: String) throws -> OrbMachineRecord? {
        try machine(identifier: recordID)
    }

    func create(_ spec: MachineSpec, owner: OwnerMarker) throws {
        let cloudInitURL = try CloudInitTemporaryFile.create(
            marker: owner,
            in: temporaryDirectoryURL
        )
        defer { try? FileManager.default.removeItem(at: cloudInitURL) }

        let operation = "Ubuntu 작업공간 만들기"
        _ = try runner.run(CommandRequest(
            executableURL: executableURL,
            arguments: [
                "create",
                "--isolated",
                "--isolate-network",
                "--memory", "2G",
                "--cpus", String(spec.cpuCount),
                "--disk", "\(spec.diskGiB)G",
                "--user-data", cloudInitURL.path,
                spec.image,
                spec.name
            ],
            operation: operation
        )).checked(operation: operation)
    }

    func ownerMarker(machineName: String) throws -> OwnerMarker? {
        let result = try runner.run(CommandRequest(
            executableURL: executableURL,
            arguments: ["run", "-m", machineName, "-u", "root", "/bin/cat", Self.ownerPath],
            operation: "작업공간 소유 확인"
        ))
        guard result.exitCode == 0 else { return nil }
        do {
            return try JSONDecoder().decode(OwnerMarker.self, from: result.standardOutput)
        } catch {
            return nil
        }
    }

    func delete(recordID: String, expectedName: String) throws {
        let operation = "Ubuntu 작업공간 제거"
        _ = try runner.run(CommandRequest(
            executableURL: executableURL,
            arguments: ["delete", "--force", recordID],
            operation: operation
        )).checked(operation: operation)

        for attempt in 0..<10 {
            if try machine(recordID: recordID) == nil,
               try machine(named: expectedName) == nil {
                return
            }
            if attempt < 9 { Thread.sleep(forTimeInterval: 0.2) }
        }
        throw SafeInstallerError(.verificationFailed, "Ubuntu 작업공간 제거 결과를 확인하지 못해 설치 기록을 보존했습니다.")
    }

    private func machine(identifier: String) throws -> OrbMachineRecord? {
        let operation = "Ubuntu 작업공간 확인"
        let result = try runner.run(CommandRequest(
            executableURL: executableURL,
            arguments: ["info", "--format", "json", identifier],
            operation: operation
        ))

        if result.exitCode != 0 {
            if result.exitCode == 1 && result.stderrString.contains("[-32098] machine not found:") {
                return nil
            }
            throw SafeInstallerError.commandFailed(operation: operation, exitCode: result.exitCode)
        }

        do {
            let response = try JSONDecoder().decode(OrbInfoEnvelope.self, from: result.standardOutput)
            let cpuCount = try configInteger(machineName: response.record.name, key: "cpu")
            let diskBytes = try configUnsignedInteger(machineName: response.record.name, key: "disk_bytes")
            return OrbMachineRecord(
                id: response.record.id,
                name: response.record.name,
                distro: response.record.image.distro,
                version: response.record.image.version,
                architecture: response.record.image.arch,
                isolated: response.record.config.isolated,
                isolateNetwork: response.record.config.isolateNetwork,
                forwardSSHAgent: response.record.config.forwardSSHAgent,
                memoryLimitMiB: response.record.config.memoryLimitMiB,
                cpuCount: cpuCount,
                diskBytes: diskBytes,
                state: response.record.state
            )
        } catch {
            throw SafeInstallerError(.invalidResponse, "Ubuntu 작업공간 정보를 읽지 못했습니다. 자동 변경을 중단했습니다.")
        }
    }

    private func configInteger(machineName: String, key: String) throws -> Int {
        guard let value = Int(try configValue(machineName: machineName, key: key)) else {
            throw SafeInstallerError(.invalidResponse, "Ubuntu 작업공간 제한값을 읽지 못했습니다.")
        }
        return value
    }

    private func configUnsignedInteger(machineName: String, key: String) throws -> UInt64 {
        guard let value = UInt64(try configValue(machineName: machineName, key: key)) else {
            throw SafeInstallerError(.invalidResponse, "Ubuntu 작업공간 제한값을 읽지 못했습니다.")
        }
        return value
    }

    private func configValue(machineName: String, key: String) throws -> String {
        let operation = "Ubuntu 작업공간 제한 확인"
        let result = try runner.run(CommandRequest(
            executableURL: executableURL,
            arguments: ["config", "get", "machine.\(machineName).\(key)"],
            operation: operation
        )).checked(operation: operation)
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw SafeInstallerError(.invalidResponse, "Ubuntu 작업공간 제한값을 읽지 못했습니다.")
        }
        return value
    }
}

private enum CloudInitTemporaryFile {
    static func create(marker: OwnerMarker, in directoryURL: URL) throws -> URL {
        let markerData: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            markerData = try encoder.encode(marker)
        } catch {
            throw SafeInstallerError(.stateWriteFailed, "설치 준비 파일을 만들지 못했습니다.")
        }

        let cloudConfig = """
        #cloud-config
        write_files:
          - path: /etc/k-ai-installer/owner.json
            owner: root:root
            permissions: '0600'
            encoding: b64
            content: \(markerData.base64EncodedString())
        """
        let url = directoryURL.appendingPathComponent("k-ai-cloud-init-\(UUID().uuidString).yaml")
        let data = Data(cloudConfig.utf8)

        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw SafeInstallerError(.stateWriteFailed, "설치 준비 파일을 안전하게 만들지 못했습니다.")
        }
        defer { close(descriptor) }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var bytesWritten = 0
                while bytesWritten < rawBuffer.count {
                    let count = write(descriptor, baseAddress.advanced(by: bytesWritten), rawBuffer.count - bytesWritten)
                    guard count > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    bytesWritten += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw SafeInstallerError(.stateWriteFailed, "설치 준비 파일을 안전하게 만들지 못했습니다.")
        }
    }
}
