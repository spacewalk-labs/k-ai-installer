import Foundation

public struct HostProbe: Codable, Equatable, Sendable {
    public let model: String
    public let architecture: String
    public let macOSVersion: String
    public let macOSBuild: String
    public let freeDiskBytes: UInt64
    public let fileVault: FileVaultStatus
    public let orbStack: OrbStackProbe

    public init(
        model: String,
        architecture: String,
        macOSVersion: String,
        macOSBuild: String,
        freeDiskBytes: UInt64,
        fileVault: FileVaultStatus,
        orbStack: OrbStackProbe
    ) {
        self.model = model
        self.architecture = architecture
        self.macOSVersion = macOSVersion
        self.macOSBuild = macOSBuild
        self.freeDiskBytes = freeDiskBytes
        self.fileVault = fileVault
        self.orbStack = orbStack
    }
}

public enum FileVaultStatus: String, Codable, Equatable, Sendable {
    case on
    case off
    case unknown
}

public struct OrbStackProbe: Codable, Equatable, Sendable {
    public let installed: Bool
    public let trusted: Bool
    public let version: String?

    public init(installed: Bool, trusted: Bool, version: String?) {
        self.installed = installed
        self.trusted = trusted
        self.version = version
    }
}

public struct MachineSpec: Codable, Equatable, Sendable {
    public let name: String
    public let image: String
    public let architecture: String
    public let memoryMiB: Int
    public let cpuCount: Int
    public let diskGiB: Int

    public static let development = MachineSpec(
        name: "k-ai-dev",
        image: "ubuntu:noble",
        architecture: "arm64",
        memoryMiB: 2_048,
        cpuCount: 2,
        diskGiB: 24
    )

    public static let runner = MachineSpec(
        name: "k-ai-runner",
        image: "ubuntu:noble",
        architecture: "arm64",
        memoryMiB: 2_048,
        cpuCount: 2,
        diskGiB: 24
    )

    public static let required: [MachineSpec] = [.development, .runner]
}

public struct InstallerProgress: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Equatable, Sendable {
        case checkingHost
        case preparing
        case creatingDevelopment
        case creatingRunner
        case verifying
        case rollingBack
        case complete
    }

    public let stage: Stage
    public let message: String

    public init(stage: Stage, message: String) {
        self.stage = stage
        self.message = message
    }
}

public struct MachineVerification: Codable, Equatable, Sendable {
    public let name: String
    public let recordID: String
    public let image: String
    public let architecture: String
    public let isolated: Bool
    public let networkIsolated: Bool
    public let sshAgentForwarding: Bool
    public let memoryMiB: Int?
    public let cpuCount: Int?
    public let diskBytes: UInt64?
    public let owned: Bool

    public init(
        name: String,
        recordID: String,
        image: String,
        architecture: String,
        isolated: Bool,
        networkIsolated: Bool,
        sshAgentForwarding: Bool,
        memoryMiB: Int?,
        cpuCount: Int?,
        diskBytes: UInt64?,
        owned: Bool
    ) {
        self.name = name
        self.recordID = recordID
        self.image = image
        self.architecture = architecture
        self.isolated = isolated
        self.networkIsolated = networkIsolated
        self.sshAgentForwarding = sshAgentForwarding
        self.memoryMiB = memoryMiB
        self.cpuCount = cpuCount
        self.diskBytes = diskBytes
        self.owned = owned
    }
}

public struct VerificationReport: Codable, Equatable, Sendable {
    public let installID: String
    public let machines: [MachineVerification]
    public let verified: Bool

    public init(installID: String, machines: [MachineVerification], verified: Bool) {
        self.installID = installID
        self.machines = machines
        self.verified = verified
    }
}

public struct SupportDiagnosticMachine: Codable, Equatable, Sendable {
    public let name: String
    public let image: String
    public let architecture: String
    public let isolated: Bool
    public let networkIsolated: Bool
    public let sshAgentForwarding: Bool
    public let memoryMiB: Int?
    public let cpuCount: Int?
    public let diskBytes: UInt64?
    public let owned: Bool

    public init(from verification: MachineVerification) {
        name = verification.name
        image = verification.image
        architecture = verification.architecture
        isolated = verification.isolated
        networkIsolated = verification.networkIsolated
        sshAgentForwarding = verification.sshAgentForwarding
        memoryMiB = verification.memoryMiB
        cpuCount = verification.cpuCount
        diskBytes = verification.diskBytes
        owned = verification.owned
    }
}

public struct SupportDiagnostics: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let host: HostProbe
    public let statePresent: Bool
    public let recoveryPending: Bool
    public let lastVerificationSucceeded: Bool
    public let recordedMachineNames: [String]
    public let machines: [SupportDiagnosticMachine]

    public init(
        generatedAt: String,
        host: HostProbe,
        statePresent: Bool,
        recoveryPending: Bool,
        lastVerificationSucceeded: Bool,
        recordedMachineNames: [String],
        machines: [SupportDiagnosticMachine]
    ) {
        self.generatedAt = generatedAt
        self.host = host
        self.statePresent = statePresent
        self.recoveryPending = recoveryPending
        self.lastVerificationSucceeded = lastVerificationSucceeded
        self.recordedMachineNames = recordedMachineNames
        self.machines = machines
    }
}

public enum FailurePoint: String, Codable, Equatable, Sendable {
    case beforeDevelopmentCreate
    case afterDevelopmentCreateBeforeOwnerCheck
    case afterDevelopmentOwnership
    case beforeRunnerCreate
    case afterRunnerCreateBeforeOwnerCheck
    case afterRunnerOwnership
    case beforeFinalVerify
    case afterRollbackDeleteBeforeState
}
