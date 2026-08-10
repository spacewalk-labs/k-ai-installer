import CryptoKit
import KAIInstallerCore
import SwiftUI

private enum InstallerEvent: Sendable {
    case progress(InstallerProgress)
    case completed(VerificationReport)
    case failed(SafeInstallerError)
}

@MainActor
private final class InstallerViewModel: ObservableObject {
    @Published var hostState = "대기 중"
    @Published var workspaceState = "대기 중"
    @Published var verificationState = "대기 중"
    @Published var detail = "이 Mac을 확인하고 안전한 Ubuntu 작업공간 두 개를 준비합니다."
    @Published var isRunning = false
    @Published var isComplete = false

    var buttonTitle: String {
        if isRunning { return "준비하는 중…" }
        if isComplete { return "준비 완료" }
        return "다시 시도"
    }

    func start(receiptAction: String = "manual-retry") {
        guard !isRunning, !isComplete else { return }
        isRunning = true
        detail = "잠시만 기다려 주세요. 창을 닫아도 다시 열어 이어갈 수 있습니다."
        hostState = "확인 중"
        workspaceState = "대기 중"
        verificationState = "대기 중"

        do {
            try writeActionReceipt(action: receiptAction)
        } catch {
            fail(SafeInstallerError(.stateWriteFailed, "설치 기록을 준비하지 못했습니다. 다시 시도해 주세요."))
            return
        }

        let stream = AsyncStream<InstallerEvent> { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let report = try KAIInstaller().apply { progress in
                        continuation.yield(.progress(progress))
                    }
                    continuation.yield(.completed(report))
                } catch let error as SafeInstallerError {
                    continuation.yield(.failed(error))
                } catch {
                    continuation.yield(.failed(SafeInstallerError(
                        .commandFailed,
                        "설치를 완료하지 못했습니다. 다시 시도해 주세요."
                    )))
                }
                continuation.finish()
            }
        }

        Task {
            for await event in stream {
                switch event {
                case let .progress(progress):
                    update(progress)
                case let .completed(report):
                    complete(report)
                case let .failed(error):
                    fail(error)
                }
            }
        }
    }

    private func update(_ progress: InstallerProgress) {
        switch progress.stage {
        case .checkingHost:
            hostState = "확인 중"
        case .preparing:
            hostState = "확인 완료"
            workspaceState = "준비 중"
        case .creatingDevelopment, .creatingRunner:
            hostState = "확인 완료"
            workspaceState = "만드는 중"
        case .verifying:
            hostState = "확인 완료"
            workspaceState = "생성 완료"
            verificationState = "확인 중"
        case .rollingBack:
            workspaceState = "정리 중"
        case .complete:
            hostState = "확인 완료"
            workspaceState = "생성 완료"
            verificationState = "확인 완료"
        }
        detail = progress.message
    }

    private func complete(_ report: VerificationReport) {
        guard report.verified, report.machines.count == 2 else {
            fail(SafeInstallerError(.verificationFailed, "Ubuntu 작업공간 확인이 끝나지 않았습니다. 다시 시도해 주세요."))
            return
        }
        isRunning = false
        isComplete = true
        hostState = "확인 완료"
        workspaceState = "생성 완료"
        verificationState = "확인 완료"
        detail = "준비가 끝났습니다. 이 창을 닫아도 됩니다."
    }

    private func fail(_ error: SafeInstallerError) {
        isRunning = false
        isComplete = false
        detail = error.message
        if hostState == "확인 중" { hostState = "확인 필요" }
        if workspaceState == "만드는 중" || workspaceState == "준비 중" { workspaceState = "이어하기 필요" }
        if verificationState == "확인 중" { verificationState = "이어하기 필요" }
    }

    private func writeActionReceipt(action: String) throws {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("KAI Installer", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)

        guard let executable = Bundle.main.executableURL else {
            throw SafeInstallerError(.stateWriteFailed, "앱 정보를 확인하지 못했습니다.")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: executable))
            .map { String(format: "%02x", $0) }
            .joined()
        let receipt: [String: Any] = [
            "action": action,
            "binarySHA256": digest,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        let temporary = support.appendingPathComponent("ui-action.json.tmp")
        let destination = support.appendingPathComponent("ui-action.json")
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}

private struct StepRow: View {
    let title: String
    let state: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.contains("완료") ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(state.contains("완료") ? .green : .secondary)
            Text(title)
                .font(.headline)
            Spacer()
            Text(state)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct InstallerView: View {
    @StateObject private var model = InstallerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("K-AI 설치")
                    .font(.largeTitle.bold())
                Text("Mac mini를 K-AI 작업용으로 준비합니다.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                StepRow(title: "이 Mac 확인", state: model.hostState)
                Divider()
                StepRow(title: "Ubuntu 작업공간 2개 만들기", state: model.workspaceState)
                Divider()
                StepRow(title: "안전 설정 확인", state: model.verificationState)
            }
            .padding(.horizontal, 16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))

            Text(model.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(model.buttonTitle) {
                model.start()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isRunning || model.isComplete)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(28)
        .frame(width: 600, height: 440)
        .onAppear {
            model.start(receiptAction: "app-launch")
        }
    }
}

@main
private struct KAIInstallerApplication: App {
    var body: some Scene {
        WindowGroup {
            InstallerView()
        }
        .windowResizability(.contentSize)
    }
}
