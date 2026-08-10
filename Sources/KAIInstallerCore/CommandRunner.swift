import Foundation

public struct CommandRequest: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let standardInput: Data?
    public let operation: String

    public init(
        executableURL: URL,
        arguments: [String],
        standardInput: Data? = nil,
        operation: String
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.operation = operation
    }
}

public struct CommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public init(exitCode: Int32, stdout: String, stderr: String = "") {
        self.init(
            exitCode: exitCode,
            standardOutput: Data(stdout.utf8),
            standardError: Data(stderr.utf8)
        )
    }
}

public protocol CommandRunning: Sendable {
    func run(_ request: CommandRequest) throws -> CommandResult
}

public final class FoundationCommandRunner: CommandRunning, @unchecked Sendable {
    public init() {}

    public func run(_ request: CommandRequest) throws -> CommandResult {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        var inputPipe: Pipe?
        if request.standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        }

        do {
            try process.run()
        } catch {
            throw SafeInstallerError.commandFailed(operation: request.operation)
        }

        let readGroup = DispatchGroup()
        let outputReader = AsynchronousPipeReader(handle: outputPipe.fileHandleForReading)
        let errorReader = AsynchronousPipeReader(handle: errorPipe.fileHandleForReading)
        outputReader.start(group: readGroup)
        errorReader.start(group: readGroup)

        if let standardInput = request.standardInput, let inputPipe {
            inputPipe.fileHandleForWriting.write(standardInput)
            try? inputPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        readGroup.wait()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: outputReader.data,
            standardError: errorReader.data
        )
    }
}

private final class AsynchronousPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var storedData = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    var data: Data {
        lock.withLock { storedData }
    }

    func start(group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let readData = handle.readDataToEndOfFile()
            lock.withLock { storedData = readData }
            group.leave()
        }
    }
}

extension CommandResult {
    func checked(operation: String) throws -> CommandResult {
        guard exitCode == 0 else {
            throw SafeInstallerError.commandFailed(operation: operation, exitCode: exitCode)
        }
        return self
    }

    var stdoutString: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var stderrString: String {
        String(decoding: standardError, as: UTF8.self)
    }
}
