import Darwin
import Foundation
import KAIInstallerCore

@main
private enum KAIInstallerCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as SafeInstallerError {
            writeError(error)
            exit(1)
        } catch {
            writeError(SafeInstallerError(.commandFailed, "요청을 완료하지 못했습니다."))
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw SafeInstallerError(.invalidResponse, usage)
        }
        let installer = KAIInstaller()

        switch command {
        case "probe":
            guard arguments.dropFirst().allSatisfy({ $0 == "--json" }) else {
                throw SafeInstallerError(.invalidResponse, usage)
            }
            FileHandle.standardOutput.write(try installer.probeJSON())
            FileHandle.standardOutput.write(Data("\n".utf8))
        case "apply":
            guard arguments.count == 1 else { throw SafeInstallerError(.invalidResponse, usage) }
            try writeJSON(installer.apply())
        case "verify":
            guard arguments.count == 1 else { throw SafeInstallerError(.invalidResponse, usage) }
            try writeJSON(installer.verify())
        case "diagnostics":
            guard arguments.count == 3, arguments[1] == "--output" else {
                throw SafeInstallerError(.invalidResponse, usage)
            }
            try installer.writeSupportDiagnostics(to: URL(fileURLWithPath: arguments[2]))
            FileHandle.standardOutput.write(Data("진단 파일을 만들었습니다.\n".utf8))
        case "rollback":
            try validateRollback(arguments)
            try installer.rollback()
            FileHandle.standardOutput.write(Data("정리가 완료되었습니다.\n".utf8))
        default:
            throw SafeInstallerError(.invalidResponse, usage)
        }
    }

    private static func validateRollback(_ arguments: [String]) throws {
        guard arguments.contains("--require-owner") else {
            throw SafeInstallerError(.rollbackRefused, "소유권 확인 옵션이 없어 정리를 중단했습니다.")
        }
        var names: [String] = []
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--require-owner":
                index += 1
            case "--machine":
                guard index + 1 < arguments.count else {
                    throw SafeInstallerError(.invalidResponse, usage)
                }
                names.append(arguments[index + 1])
                index += 2
            default:
                throw SafeInstallerError(.invalidResponse, usage)
            }
        }
        guard Set(names) == Set(MachineSpec.required.map(\.name)), names.count == 2 else {
            throw SafeInstallerError(.rollbackRefused, "이 설치가 만든 Ubuntu 두 개만 정리할 수 있습니다.")
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func writeError(_ error: SafeInstallerError) {
        let payload = ["code": error.code.rawValue, "message": error.message]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }

    private static let usage = """
    사용법:
      kai-installer-cli probe --json
      kai-installer-cli apply
      kai-installer-cli verify
      kai-installer-cli diagnostics --output <path>
      kai-installer-cli rollback --require-owner --machine k-ai-dev --machine k-ai-runner
    """
}
