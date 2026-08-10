import Foundation

public protocol FailureInjecting: Sendable {
    func hit(_ point: FailurePoint) throws
}

public struct NoFailureInjector: FailureInjecting {
    public init() {}
    public func hit(_ point: FailurePoint) throws {}
}

protocol InstallIDGenerating: Sendable {
    func generate() -> String
}

struct UUIDInstallIDGenerator: InstallIDGenerating {
    func generate() -> String { UUID().uuidString.lowercased() }
}

protocol InstallerSleeping: Sendable {
    func sleepForOwnerMarkerAttempt()
}

struct ThreadInstallerSleeper: InstallerSleeping {
    func sleepForOwnerMarkerAttempt() {
        Thread.sleep(forTimeInterval: 1)
    }
}

public final class KAIInstaller: @unchecked Sendable {
    public static var defaultStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/KAI Installer/state.json")
    }

    private let runner: any CommandRunning
    private let resolver: any OrbStackResolving
    private let stateStore: any InstallerStateStoring
    private let transactionLock: InstallerTransactionLock
    private let nonceGenerator: any NonceGenerating
    private let installIDGenerator: any InstallIDGenerating
    private let failureInjector: any FailureInjecting
    private let sleeper: any InstallerSleeping
    private let temporaryDirectoryURL: URL

    public convenience init() {
        let runner = FoundationCommandRunner()
        self.init(
            runner: runner,
            resolver: NotarizedOrbStackResolver(runner: runner),
            stateURL: Self.defaultStateURL
        )
    }

    public convenience init(
        runner: any CommandRunning,
        resolver: any OrbStackResolving,
        stateURL: URL,
        failureInjector: any FailureInjecting = NoFailureInjector()
    ) {
        self.init(
            runner: runner,
            resolver: resolver,
            stateStore: JSONInstallerStateStore(stateURL: stateURL),
            nonceGenerator: SecureNonceGenerator(),
            installIDGenerator: UUIDInstallIDGenerator(),
            failureInjector: failureInjector,
            sleeper: ThreadInstallerSleeper(),
            temporaryDirectoryURL: FileManager.default.temporaryDirectory
        )
    }

    init(
        runner: any CommandRunning,
        resolver: any OrbStackResolving,
        stateStore: any InstallerStateStoring,
        nonceGenerator: any NonceGenerating,
        installIDGenerator: any InstallIDGenerating,
        failureInjector: any FailureInjecting,
        sleeper: any InstallerSleeping,
        temporaryDirectoryURL: URL
    ) {
        self.runner = runner
        self.resolver = resolver
        self.stateStore = stateStore
        self.transactionLock = InstallerTransactionLock(stateURL: stateStore.stateURL)
        self.nonceGenerator = nonceGenerator
        self.installIDGenerator = installIDGenerator
        self.failureInjector = failureInjector
        self.sleeper = sleeper
        self.temporaryDirectoryURL = temporaryDirectoryURL
    }

    public func probe() throws -> HostProbe {
        try HostProber(runner: runner, resolver: resolver).probe()
    }

    public func probeJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(probe())
    }

    public func apply(progress: ((InstallerProgress) -> Void)? = nil) throws -> VerificationReport {
        try transactionLock.withLock {
            progress?(InstallerProgress(stage: .checkingHost, message: "이 Mac을 확인하고 있습니다."))
            let host = try probe()
            try requireSupported(host)

            let resolved = try resolver.resolve()
            let client = OrbStackClient(
                runner: runner,
                executableURL: resolved.executableURL,
                temporaryDirectoryURL: temporaryDirectoryURL
            )

        progress?(InstallerProgress(stage: .preparing, message: "안전하게 설치를 준비하고 있습니다."))
        var state: InstallerState
        var activeNonce: Data?
        if let existingState = try stateStore.load() {
            state = existingState
        } else {
            let nonce = try newNonce()
            state = InstallerState(
                installID: installIDGenerator.generate(),
                ownerNonceHash: OwnerNonce.hash(nonce)
            )
            try stateStore.save(state)
            activeNonce = nonce
        }
        guard state.pendingDeletion == nil else {
            throw SafeInstallerError(.rollbackRefused, "중단된 제거 작업이 있습니다. 지원용 제거를 다시 실행해 주세요.")
        }

        activeNonce = try recoverNonceIfPossible(state: state, client: client) ?? activeNonce

        for (index, spec) in MachineSpec.required.enumerated() {
            progress?(InstallerProgress(
                stage: index == 0 ? .creatingDevelopment : .creatingRunner,
                message: index == 0
                    ? "첫 번째 Ubuntu 작업공간을 만들고 있습니다."
                    : "두 번째 Ubuntu 작업공간을 만들고 있습니다."
            ))
            try ensureMachine(
                spec,
                state: &state,
                activeNonce: &activeNonce,
                client: client
            )
        }

        try failureInjector.hit(.beforeFinalVerify)
        progress?(InstallerProgress(stage: .verifying, message: "두 작업공간을 확인하고 있습니다."))
        let report = try verificationReport(state: state, client: client)
        state.lastVerificationSucceeded = report.verified
        try stateStore.save(state)
        guard report.verified else {
            throw SafeInstallerError(.verificationFailed, "Ubuntu 작업공간의 안전 설정을 확인하지 못했습니다. 자동 변경을 중단했습니다.")
        }

            progress?(InstallerProgress(stage: .complete, message: "설치 확인이 끝났습니다."))
            return report
        }
    }

    public func verify() throws -> VerificationReport {
        try transactionLock.withLock {
            try verifyWithoutLock()
        }
    }

    private func verifyWithoutLock() throws -> VerificationReport {
        guard var state = try stateStore.load() else {
            throw SafeInstallerError(.verificationFailed, "이 설치에서 만든 Ubuntu 작업공간 기록이 없습니다.")
        }
        guard state.pendingDeletion == nil else {
            throw SafeInstallerError(.rollbackRefused, "중단된 제거 작업이 있어 확인을 멈췄습니다.")
        }
        let resolved = try resolver.resolve()
        let client = OrbStackClient(runner: runner, executableURL: resolved.executableURL)
        let report = try verificationReport(state: state, client: client)
        state.lastVerificationSucceeded = report.verified
        try stateStore.save(state)
        return report
    }

    public func writeSupportDiagnostics(to outputURL: URL) throws {
        try transactionLock.withLock {
            let host = try probe()
            let state = try stateStore.load()
            let verification = try state.flatMap { currentState in
                currentState.pendingDeletion == nil ? try verifyWithoutLock() : nil
            }
            let refreshedState = try stateStore.load()
            let diagnostics = SupportDiagnostics(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                host: host,
                statePresent: state != nil,
                recoveryPending: refreshedState?.pendingDeletion != nil,
                lastVerificationSucceeded: refreshedState?.lastVerificationSucceeded ?? false,
                recordedMachineNames: refreshedState?.machines.map(\.name) ?? [],
                machines: verification?.machines.map(SupportDiagnosticMachine.init(from:)) ?? []
            )

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(diagnostics).write(to: outputURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: outputURL.path
                )
            } catch {
                throw SafeInstallerError(.stateWriteFailed, "진단 파일을 안전하게 저장하지 못했습니다.")
            }
        }
    }

    public func rollback(progress: ((InstallerProgress) -> Void)? = nil) throws {
        try transactionLock.withLock {
            guard var state = try stateStore.load(), !state.machines.isEmpty else {
                throw SafeInstallerError(.rollbackRefused, "이 설치에서 만든 Ubuntu 작업공간 기록이 없어 제거하지 않았습니다.")
            }
            guard state.pendingMachineName == nil else {
                throw SafeInstallerError(.rollbackRefused, "중단된 설치를 먼저 다시 시도한 뒤 제거해 주세요.")
            }

        progress?(InstallerProgress(stage: .rollingBack, message: "이 설치에서 만든 작업공간인지 확인하고 있습니다."))
            let resolved = try resolver.resolve()
            let client = OrbStackClient(runner: runner, executableURL: resolved.executableURL)

            try reconcilePendingDeletion(state: &state, client: client)
            if state.machines.isEmpty {
                try stateStore.remove()
                progress?(InstallerProgress(stage: .complete, message: "이 설치에서 만든 작업공간을 제거했습니다."))
                return
            }

        for owned in state.machines {
            guard MachineSpec.required.map(\.name).contains(owned.name),
                  let record = try client.machine(recordID: owned.recordID),
                  record.id == owned.recordID,
                  record.name == owned.name,
                  try validatedNonce(state: state, machineName: record.name, client: client) != nil
            else {
                throw SafeInstallerError(.rollbackRefused, "작업공간 소유권을 확인할 수 없어 아무것도 제거하지 않았습니다.")
            }
        }

        for owned in state.machines.reversed() {
            state.pendingDeletion = owned
            state.lastVerificationSucceeded = false
            try stateStore.save(state)
            try client.delete(recordID: owned.recordID, expectedName: owned.name)
            try failureInjector.hit(.afterRollbackDeleteBeforeState)
            state.machines.removeAll { $0.recordID == owned.recordID }
            state.pendingDeletion = nil
            if state.machines.isEmpty {
                try stateStore.remove()
            } else {
                try stateStore.save(state)
            }
        }
            progress?(InstallerProgress(stage: .complete, message: "이 설치에서 만든 작업공간을 제거했습니다."))
        }
    }

    private func reconcilePendingDeletion(
        state: inout InstallerState,
        client: OrbStackClient
    ) throws {
        guard let pending = state.pendingDeletion else { return }
        guard state.machines.contains(pending) else {
            throw SafeInstallerError(.stateCorrupt, "설치 기록의 제거 순서를 확인할 수 없습니다.")
        }

        let recordByID = try client.machine(recordID: pending.recordID)
        let recordByName = try client.machine(named: pending.name)
        if recordByID == nil, recordByName == nil {
            state.machines.removeAll { $0 == pending }
            state.pendingDeletion = nil
            if state.machines.isEmpty {
                try stateStore.remove()
            } else {
                try stateStore.save(state)
            }
            return
        }

        guard let recordByID,
              let recordByName,
              recordByID.id == pending.recordID,
              recordByID.name == pending.name,
              recordByName.id == pending.recordID,
              try validatedNonce(state: state, machineName: pending.name, client: client) != nil
        else {
            throw SafeInstallerError(.rollbackRefused, "중단된 제거 대상의 소유권을 확인할 수 없어 아무것도 제거하지 않았습니다.")
        }
    }

    private func ensureMachine(
        _ spec: MachineSpec,
        state: inout InstallerState,
        activeNonce: inout Data?,
        client: OrbStackClient
    ) throws {
        if let owned = state.machines.first(where: { $0.name == spec.name }) {
            guard let record = try client.machine(recordID: owned.recordID) else {
                throw SafeInstallerError(.ownedMachineMissing, "이 설치에서 만든 작업공간을 찾을 수 없습니다. 자동으로 다시 만들지 않았습니다.")
            }
            guard record.id == owned.recordID,
                  record.name == spec.name,
                  let nonce = try validatedNonce(state: state, machineName: record.name, client: client)
            else {
                throw ownershipConflict()
            }
            activeNonce = activeNonce ?? nonce
            return
        }

        if let existing = try client.machine(named: spec.name) {
            guard state.pendingMachineName == spec.name,
                  let nonce = try validatedNonce(state: state, machineName: existing.name, client: client)
            else {
                throw ownershipConflict()
            }
            state.machines.append(OwnedMachineState(name: spec.name, recordID: existing.id))
            state.pendingMachineName = nil
            state.lastVerificationSucceeded = false
            try stateStore.save(state)
            activeNonce = activeNonce ?? nonce
            try failureInjector.hit(afterOwnershipPoint(for: spec))
            return
        }

        if state.pendingMachineName != nil && state.pendingMachineName != spec.name {
            throw SafeInstallerError(.stateCorrupt, "설치 기록의 진행 순서를 확인할 수 없어 자동 변경을 중단했습니다.")
        }
        if activeNonce == nil {
            guard state.machines.isEmpty else {
                throw ownershipConflict()
            }
            let replacement = try newNonce()
            state.ownerNonceHash = OwnerNonce.hash(replacement)
            activeNonce = replacement
        }
        guard let nonce = activeNonce else {
            throw ownershipConflict()
        }

        state.pendingMachineName = spec.name
        state.lastVerificationSucceeded = false
        try stateStore.save(state)

        try failureInjector.hit(beforeCreatePoint(for: spec))
        try client.create(
            spec,
            owner: OwnerMarker(installID: state.installID, ownerNonce: OwnerNonce.encode(nonce))
        )
        try failureInjector.hit(afterCreatePoint(for: spec))

        guard let record = try client.machine(named: spec.name),
              let verifiedNonce = try waitForValidatedNonce(
                  state: state,
                  machineName: record.name,
                  client: client
              )
        else {
            throw ownershipConflict()
        }
        activeNonce = verifiedNonce
        state.machines.append(OwnedMachineState(name: spec.name, recordID: record.id))
        state.pendingMachineName = nil
        try stateStore.save(state)
        try failureInjector.hit(afterOwnershipPoint(for: spec))
    }

    private func recoverNonceIfPossible(state: InstallerState, client: OrbStackClient) throws -> Data? {
        for owned in state.machines {
            guard let record = try client.machine(recordID: owned.recordID) else {
                throw SafeInstallerError(.ownedMachineMissing, "이 설치에서 만든 작업공간을 찾을 수 없습니다. 자동으로 다시 만들지 않았습니다.")
            }
            guard record.id == owned.recordID,
                  record.name == owned.name,
                  let nonce = try validatedNonce(state: state, machineName: record.name, client: client)
            else {
                throw ownershipConflict()
            }
            return nonce
        }

        if let pendingName = state.pendingMachineName,
           let record = try client.machine(named: pendingName) {
            guard record.name == pendingName,
                  let nonce = try waitForValidatedNonce(state: state, machineName: pendingName, client: client)
            else {
                throw ownershipConflict()
            }
            return nonce
        }
        return nil
    }

    private func verificationReport(state: InstallerState, client: OrbStackClient) throws -> VerificationReport {
        var results: [MachineVerification] = []

        for spec in MachineSpec.required {
            guard let owned = state.machines.first(where: { $0.name == spec.name }),
                  let record = try client.machine(recordID: owned.recordID)
            else {
                results.append(MachineVerification(
                    name: spec.name,
                    recordID: "",
                    image: "",
                    architecture: "",
                    isolated: false,
                    networkIsolated: false,
                    sshAgentForwarding: true,
                    memoryMiB: nil,
                    cpuCount: nil,
                    diskBytes: nil,
                    owned: false
                ))
                continue
            }

            let ownedByInstaller = try validatedNonce(
                state: state,
                machineName: record.name,
                client: client
            ) != nil && record.id == owned.recordID && record.name == spec.name
            results.append(MachineVerification(
                name: record.name,
                recordID: record.id,
                image: "\(record.distro):\(record.version)",
                architecture: record.architecture,
                isolated: record.isolated == true,
                networkIsolated: record.isolateNetwork == true,
                sshAgentForwarding: record.forwardSSHAgent ?? true,
                memoryMiB: record.memoryLimitMiB,
                cpuCount: record.cpuCount,
                diskBytes: record.diskBytes,
                owned: ownedByInstaller
            ))
        }

        let verified = results.count == MachineSpec.required.count && zip(results, MachineSpec.required).allSatisfy { result, spec in
            result.name == spec.name
                && result.image == spec.image
                && result.architecture == spec.architecture
                && result.isolated
                && result.networkIsolated
                && !result.sshAgentForwarding
                && result.memoryMiB == spec.memoryMiB
                && result.cpuCount == spec.cpuCount
                && result.diskBytes == UInt64(spec.diskGiB) * 1_024 * 1_024 * 1_024
                && result.owned
        }
        return VerificationReport(installID: state.installID, machines: results, verified: verified)
    }

    private func validatedNonce(
        state: InstallerState,
        machineName: String,
        client: OrbStackClient
    ) throws -> Data? {
        guard let marker = try client.ownerMarker(machineName: machineName),
              marker.installID == state.installID,
              let nonce = OwnerNonce.decode(marker.ownerNonce),
              nonce.count == 32,
              OwnerNonce.hash(nonce) == state.ownerNonceHash
        else { return nil }
        return nonce
    }

    private func waitForValidatedNonce(
        state: InstallerState,
        machineName: String,
        client: OrbStackClient
    ) throws -> Data? {
        for attempt in 0..<30 {
            if let nonce = try validatedNonce(state: state, machineName: machineName, client: client) {
                return nonce
            }
            if attempt < 29 { sleeper.sleepForOwnerMarkerAttempt() }
        }
        return nil
    }

    private func requireSupported(_ host: HostProbe) throws {
        let majorVersion = Int(host.macOSVersion.split(separator: ".").first ?? "") ?? 0
        guard host.architecture == "arm64", majorVersion >= 14 else {
            throw SafeInstallerError(.unsupportedHost, "Apple Silicon과 macOS 14 이상이 필요합니다.")
        }
        guard host.freeDiskBytes >= 80 * 1_024 * 1_024 * 1_024 else {
            throw SafeInstallerError(.unsupportedHost, "남은 저장 공간이 80GB 이상 필요합니다.")
        }
        guard host.orbStack.installed else {
            throw SafeInstallerError(.orbStackUnavailable, "OrbStack이 필요합니다. OrbStack을 먼저 설치해 주세요.")
        }
        guard host.orbStack.trusted else {
            throw SafeInstallerError(.orbStackUntrusted, "공식 OrbStack인지 확인하지 못했습니다.")
        }
    }

    private func newNonce() throws -> Data {
        let nonce = try nonceGenerator.generate()
        guard nonce.count == 32 else {
            throw SafeInstallerError(.stateWriteFailed, "안전한 설치 식별자를 만들지 못했습니다.")
        }
        return nonce
    }

    private func beforeCreatePoint(for spec: MachineSpec) -> FailurePoint {
        spec.name == MachineSpec.development.name ? .beforeDevelopmentCreate : .beforeRunnerCreate
    }

    private func afterCreatePoint(for spec: MachineSpec) -> FailurePoint {
        spec.name == MachineSpec.development.name
            ? .afterDevelopmentCreateBeforeOwnerCheck
            : .afterRunnerCreateBeforeOwnerCheck
    }

    private func afterOwnershipPoint(for spec: MachineSpec) -> FailurePoint {
        spec.name == MachineSpec.development.name ? .afterDevelopmentOwnership : .afterRunnerOwnership
    }

    private func ownershipConflict() -> SafeInstallerError {
        SafeInstallerError(
            .ownershipConflict,
            "같은 이름의 Ubuntu 작업공간 소유권을 확인할 수 없어 자동 변경을 중단했습니다."
        )
    }
}
