import Darwin
import Foundation

final class InstallerTransactionLock: @unchecked Sendable {
    private let lockURL: URL
    private let fileManager: FileManager

    init(stateURL: URL, fileManager: FileManager = .default) {
        lockURL = stateURL.deletingLastPathComponent().appendingPathComponent(".transaction.lock")
        self.fileManager = fileManager
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let directoryURL = lockURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        } catch {
            throw SafeInstallerError(.stateWriteFailed, "설치 잠금 파일을 준비하지 못했습니다.")
        }

        let descriptor = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SafeInstallerError(.stateWriteFailed, "설치 잠금 파일을 열지 못했습니다.")
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == geteuid(),
              status.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0
        else {
            throw SafeInstallerError(.stateWriteFailed, "설치 잠금 파일을 안전하게 확인하지 못했습니다.")
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw SafeInstallerError(.transactionBusy, "다른 설치 확인이 진행 중입니다. 잠시 뒤 다시 시도해 주세요.")
            }
            throw SafeInstallerError(.stateWriteFailed, "설치 잠금을 시작하지 못했습니다.")
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        return try body()
    }
}
