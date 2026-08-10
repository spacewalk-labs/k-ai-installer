import Foundation

public struct SafeInstallerError: Error, Codable, Equatable, LocalizedError, Sendable {
    public enum Code: String, Codable, Equatable, Sendable {
        case unsupportedHost
        case orbStackUnavailable
        case orbStackUntrusted
        case commandFailed
        case invalidResponse
        case stateCorrupt
        case stateWriteFailed
        case transactionBusy
        case ownershipConflict
        case ownedMachineMissing
        case verificationFailed
        case rollbackRefused
        case injectedFailure
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    static func commandFailed(operation: String, exitCode: Int32? = nil) -> SafeInstallerError {
        let suffix = exitCode.map { " (code \($0))" } ?? ""
        return SafeInstallerError(.commandFailed, "\(operation)을 완료하지 못했습니다\(suffix). 다시 시도해 주세요.")
    }
}
