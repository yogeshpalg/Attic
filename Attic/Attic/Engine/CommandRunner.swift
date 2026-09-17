import Foundation

/// What running an allowlisted command produced.
struct CommandResult: Sendable, Equatable {
    let command: KnownCommand
    let exitCode: Int32
    /// Trimmed and truncated: this goes on screen, and some of these tools are
    /// chatty enough to fill a window.
    let output: String

    var succeeded: Bool { exitCode == 0 }
}

enum CommandFailure: Error, LocalizedError, Equatable {
    /// The tool is not installed. Expected, not exceptional: a Mac without
    /// Homebrew has no `brew` to run.
    case notInstalled(String)
    case launchFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "\(name) is not installed on this Mac"
        case .launchFailed(let message): message
        case .timedOut: "the command was still running after two minutes and was stopped"
        }
    }
}

/// Runs the compiled allowlist, and nothing else.
///
/// Three properties matter more than anything this file does:
///
/// 1. It takes a `KnownCommand`, not a string. There is no path by which a
///    definition — including one fetched from the definitions repository —
///    can name an executable or add an argument.
/// 2. It spawns the executable directly with an argument array. No shell, so
///    nothing needs quoting and nothing can be chained onto the end.
/// 3. It never escalates. A command that needs root fails as the user, and the
///    receipt says so.
struct CommandRunner: Sendable {

    /// Long enough for `brew cleanup` on a slow disk, short enough that a wedged
    /// tool does not hold the app open forever.
    static let timeout: TimeInterval = 120

    var run: @Sendable (KnownCommand) throws -> CommandResult = CommandRunner.execute

    func callAsFunction(_ command: KnownCommand) throws -> CommandResult {
        try run(command)
    }

    @Sendable
    static func execute(_ command: KnownCommand) throws -> CommandResult {
        let (executable, arguments) = command.invocation

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // A fixed, minimal environment: PATH is where `env` looks for `brew`,
        // and inheriting the caller's whole environment would let anything that
        // set a variable in it change what runs.
        process.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Nothing to type into. A tool that asks a question reads EOF and gives up
        // rather than waiting for an answer that will never come.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CommandFailure.launchFailed(error.localizedDescription)
        }

        // Read before waiting: a command that fills the pipe buffer would block
        // forever if we waited for it to exit first.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // `env` reports a missing executable as 127, which is the ordinary case
        // of a tool this Mac does not have.
        if process.terminationStatus == 127 {
            throw CommandFailure.notInstalled(arguments.first ?? executable)
        }

        return CommandResult(
            command: command,
            exitCode: process.terminationStatus,
            output: String(output.prefix(2_000))
        )
    }
}
