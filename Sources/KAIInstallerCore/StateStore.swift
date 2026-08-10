import CryptoKit
import Darwin
import Foundation

struct OwnedMachineState: Codable, Equatable, Sendable {
    let name: String
    let recordID: String
}

struct InstallerState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let installID: String
    var ownerNonceHash: String
    var pendingMachineName: String?
    var pendingDeletion: OwnedMachineState?
    var machines: [OwnedMachineState]
    var lastVerificationSucceeded: Bool

    init(
        installID: String,
        ownerNonceHash: String,
        pendingMachineName: String? = nil,
        pendingDeletion: OwnedMachineState? = nil,
        machines: [OwnedMachineState] = [],
        lastVerificationSucceeded: Bool = false
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.installID = installID
        self.ownerNonceHash = ownerNonceHash
        self.pendingMachineName = pendingMachineName
        self.pendingDeletion = pendingDeletion
        self.machines = machines
        self.lastVerificationSucceeded = lastVerificationSucceeded
    }
}

protocol InstallerStateStoring: Sendable {
    var stateURL: URL { get }
    func load() throws -> InstallerState?
    func save(_ state: InstallerState) throws
    func remove() throws
}

final class JSONInstallerStateStore: InstallerStateStoring, @unchecked Sendable {
    let stateURL: URL
    private let fileManager: FileManager

    init(stateURL: URL, fileManager: FileManager = .default) {
        self.stateURL = stateURL
        self.fileManager = fileManager
    }

    func load() throws -> InstallerState? {
        guard fileManager.fileExists(atPath: stateURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: stateURL, options: [.mappedIfSafe])
            let state = try JSONDecoder().decode(InstallerState.self, from: data)
            guard state.schemaVersion == InstallerState.currentSchemaVersion else {
                throw SafeInstallerError(.stateCorrupt, "설치 기록의 버전을 읽을 수 없습니다. 지원을 요청해 주세요.")
            }
            guard !state.installID.isEmpty,
                  Self.isSHA256(state.ownerNonceHash),
                  Set(state.machines.map(\.name)).count == state.machines.count,
                  Set(state.machines.map(\.recordID)).count == state.machines.count,
                  state.machines.allSatisfy({ MachineSpec.required.map(\.name).contains($0.name) && !$0.recordID.isEmpty }),
                  state.machines.map(\.name) == Array(MachineSpec.required.prefix(state.machines.count).map(\.name)),
                  state.pendingMachineName.map({ pending in
                      state.machines.count < MachineSpec.required.count
                          && pending == MachineSpec.required[state.machines.count].name
                  }) ?? true,
                  state.pendingDeletion.map({ pending in
                      state.pendingMachineName == nil
                          && state.machines.contains(pending)
                          && state.machines.last == pending
                          && MachineSpec.required.map(\.name).contains(pending.name)
                  }) ?? true,
                  !state.lastVerificationSucceeded || (
                      state.machines.count == MachineSpec.required.count
                          && state.pendingMachineName == nil
                          && state.pendingDeletion == nil
                  )
            else {
                throw SafeInstallerError(.stateCorrupt, "설치 기록이 손상되었습니다. 자동으로 덮어쓰지 않았습니다.")
            }
            return state
        } catch let error as SafeInstallerError {
            throw error
        } catch {
            throw SafeInstallerError(.stateCorrupt, "설치 기록이 손상되었습니다. 자동으로 덮어쓰지 않았습니다.")
        }
    }

    func save(_ state: InstallerState) throws {
        let directoryURL = stateURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(".state-\(UUID().uuidString).tmp")

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try Self.writeSecurely(data, to: temporaryURL)

            guard rename(temporaryURL.path, stateURL.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            try? Self.syncDirectory(directoryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw SafeInstallerError(.stateWriteFailed, "설치 기록을 안전하게 저장하지 못했습니다. 디스크 공간을 확인해 주세요.")
        }
    }

    func remove() throws {
        guard fileManager.fileExists(atPath: stateURL.path) else { return }
        do {
            try fileManager.removeItem(at: stateURL)
            try? Self.syncDirectory(stateURL.deletingLastPathComponent())
        } catch {
            throw SafeInstallerError(.stateWriteFailed, "설치 기록을 정리하지 못했습니다. 다시 시도해 주세요.")
        }
    }

    private static func writeSecurely(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

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
    }

    private static func syncDirectory(_ directoryURL: URL) throws {
        let descriptor = open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}

protocol NonceGenerating: Sendable {
    func generate() throws -> Data
}

struct SecureNonceGenerator: NonceGenerating {
    func generate() throws -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

enum OwnerNonce {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
    }

    static func decode(_ value: String) -> Data? {
        Data(base64Encoded: value)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
