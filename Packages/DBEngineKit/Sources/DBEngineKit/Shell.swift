import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let output: String
}

public struct CommandError: LocalizedError {
    public let command: [String]
    public let result: CommandResult
    public var errorDescription: String? {
        "\(command.joined(separator: " ")) exited \(result.status): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Runs a program directly (no shell), merging stdout and stderr.
enum Shell {
    @discardableResult
    static func run(_ args: [String], cwd: URL? = nil, environment: [String: String] = [:],
                    check: Bool = true) throws -> CommandResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        if let cwd { p.currentDirectoryURL = cwd }
        if !environment.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        // Read before waiting so a full pipe buffer can't deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let result = CommandResult(status: p.terminationStatus,
                                   output: String(decoding: data, as: UTF8.self))
        if check && result.status != 0 { throw CommandError(command: args, result: result) }
        return result
    }
}
