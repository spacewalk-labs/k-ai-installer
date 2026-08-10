import Foundation

public struct ResolvedOrbStack: Equatable, Sendable {
    public let executableURL: URL
    public let version: String

    public init(executableURL: URL, version: String) {
        self.executableURL = executableURL
        self.version = version
    }
}

public protocol OrbStackResolving: Sendable {
    func resolve() throws -> ResolvedOrbStack
}

public final class NotarizedOrbStackResolver: OrbStackResolving, @unchecked Sendable {
    public static let bundleIdentifier = "dev.kdrag0n.MacVirt"
    public static let teamIdentifier = "HUAQ24HBR6"

    private let runner: any CommandRunning
    private let candidates: [URL]
    private let bundleURL: URL
    private let fileManager: FileManager

    public convenience init(runner: any CommandRunning = FoundationCommandRunner()) {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            runner: runner,
            candidates: [
                URL(fileURLWithPath: "/Applications/OrbStack.app/Contents/MacOS/bin/orb"),
                homeURL.appendingPathComponent(".orbstack/bin/orb")
            ],
            bundleURL: URL(fileURLWithPath: "/Applications/OrbStack.app"),
            fileManager: .default
        )
    }

    init(
        runner: any CommandRunning,
        candidates: [URL],
        bundleURL: URL,
        fileManager: FileManager
    ) {
        self.runner = runner
        self.candidates = candidates
        self.bundleURL = bundleURL
        self.fileManager = fileManager
    }

    public func resolve() throws -> ResolvedOrbStack {
        var foundCandidate = false

        for candidate in candidates {
            guard fileManager.isExecutableFile(atPath: candidate.path) else { continue }
            foundCandidate = true

            do {
                let executableURL = candidate.resolvingSymlinksInPath().standardizedFileURL
                guard isInsideTrustedBundle(executableURL) else {
                    throw untrustedError()
                }
                try verifyBundleTrust()
                let version = try verifyVersion(executableURL)
                return ResolvedOrbStack(executableURL: executableURL, version: version)
            } catch {
                continue
            }
        }

        if foundCandidate {
            throw untrustedError()
        }
        throw SafeInstallerError(.orbStackUnavailable, "OrbStack이 설치되어 있지 않습니다. OrbStack을 먼저 설치해 주세요.")
    }

    private func isInsideTrustedBundle(_ executableURL: URL) -> Bool {
        let trustedRoot = bundleURL
            .appendingPathComponent("Contents/MacOS")
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let path = executableURL.path
        return path == trustedRoot || path.hasPrefix(trustedRoot + "/")
    }

    private func verifyBundleTrust() throws {
        let assessment = try runner.run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
            arguments: ["--assess", "--type", "execute", "--verbose=2", bundleURL.path],
            operation: "OrbStack 서명 확인"
        ))
        let assessmentText = assessment.stdoutString + assessment.stderrString
        guard assessment.exitCode == 0,
              assessmentText.localizedCaseInsensitiveContains("Notarized Developer ID")
        else {
            throw untrustedError()
        }

        let signature = try runner.run(CommandRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--display", "--verbose=4", bundleURL.path],
            operation: "OrbStack 제작자 확인"
        ))
        let signatureText = signature.stdoutString + signature.stderrString
        guard signature.exitCode == 0,
              signatureText.split(whereSeparator: \.isNewline).contains("Identifier=\(Self.bundleIdentifier)"),
              signatureText.split(whereSeparator: \.isNewline).contains("TeamIdentifier=\(Self.teamIdentifier)")
        else {
            throw untrustedError()
        }
    }

    private func verifyVersion(_ executableURL: URL) throws -> String {
        let result = try runner.run(CommandRequest(
            executableURL: executableURL,
            arguments: ["version"],
            operation: "OrbStack 버전 확인"
        ))
        guard result.exitCode == 0,
              let version = Self.semanticVersion(in: result.stdoutString + result.stderrString),
              Self.isCompatible(version)
        else {
            throw untrustedError()
        }
        return version
    }

    private static func semanticVersion(in text: String) -> String? {
        let pattern = #"(?:^|[^0-9])(\d+)\.(\d+)\.(\d+)(?:[^0-9]|$)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range(at: 0), in: text)
        else { return nil }

        let matched = String(text[range])
        return matched.trimmingCharacters(in: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".")).inverted)
    }

    private static func isCompatible(_ version: String) -> Bool {
        let components = version.split(separator: ".").compactMap { Int($0) }
        return components.count == 3 && components[0] == 2 && components[1] >= 2
    }

    private func untrustedError() -> SafeInstallerError {
        SafeInstallerError(
            .orbStackUntrusted,
            "OrbStack의 제작자 또는 버전을 확인할 수 없습니다. 공식 OrbStack을 다시 설치해 주세요."
        )
    }
}
