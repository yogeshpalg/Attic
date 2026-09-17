import Testing
import Foundation
@testable import Attic

/// Invariant 18. Attic runs a closed set of commands and nothing else. The
/// allowlist is an enum, so there is no path by which a definition — including
/// one fetched from the definitions repository — can name an executable or add
/// an argument, and there is no shell to smuggle one through.
@Suite("Command allowlist")
struct CommandInvocationTests {

    @Test("Every command names an absolute executable and separate arguments")
    func invocationsAreSplitAndAbsolute() {
        let commands: [KnownCommand] = [
            .simctlDeletePreviews, .simctlDeleteUnavailable,
            .simctlRuntimeDelete(identifier: "iOS 26.4"),
            .tmutilDeleteSnapshot(name: "com.apple.TimeMachine.2026-09-15-183654"),
            .brewCleanup, .goCleanModcache, .dockerPrune(volumes: false),
        ]

        for command in commands {
            let (executable, arguments) = command.invocation

            #expect(executable.hasPrefix("/"), "\(command.displayForm) is not an absolute path")
            #expect(arguments.isEmpty == false)
            // No shell means no metacharacters to interpret: anything here is
            // literal, so there is nothing to quote and nothing to escape.
            #expect(executable.contains(" ") == false)
        }
    }

    @Test("A value inside a command stays one argument")
    func valuesCannotBecomeSecondCommands() {
        // The worst case: a definitions file names a runtime whose identifier is
        // an attempt at a second command. With an argument array it is a runtime
        // name that does not exist, and simctl says so.
        let hostile = "iOS 26.4; rm -rf ~"
        let (executable, arguments) = KnownCommand.simctlRuntimeDelete(identifier: hostile).invocation

        #expect(executable == "/usr/bin/xcrun")
        #expect(arguments == ["simctl", "runtime", "delete", hostile])
        #expect(arguments.count == 4)
        // The semicolon is inside one argument, not between two.
        #expect(arguments.last == hostile)
    }

    @Test("A snapshot name with a space stays one argument")
    func spacesDoNotSplitArguments() {
        let (_, arguments) = KnownCommand.tmutilDeleteSnapshot(name: "a name with spaces").invocation

        #expect(arguments == ["deletelocalsnapshots", "a name with spaces"])
    }

    @Test("Prune runs without asking, because nothing can answer it")
    func commandsAreNonInteractive() {
        let (_, arguments) = KnownCommand.dockerPrune(volumes: true).invocation

        // `docker system prune` prompts by default; a background process with no
        // input would wait on that prompt forever.
        #expect(arguments.contains("--force"))
        #expect(arguments.contains("--volumes"))
        #expect(KnownCommand.dockerPrune(volumes: false).invocation.arguments.contains("--volumes") == false)
    }

    @Test("What is shown matches what would run")
    func displayFormMatchesTheInvocation() {
        for command in [KnownCommand.simctlDeletePreviews, .brewCleanup, .goCleanModcache] {
            let (executable, arguments) = command.invocation
            let shown = command.displayForm

            // The display form drops `/usr/bin/env` and the absolute path, but
            // every argument a person reads is one that will be passed.
            for argument in arguments where argument != "--force" {
                #expect(shown.contains(argument), "\(shown) does not mention \(argument)")
            }
            #expect(executable.hasPrefix("/usr/bin/"))
        }
    }
}

@Suite("Running commands")
struct CommandRunnerTests {

    @Test("A command that is not installed is reported, not treated as a crash")
    func missingToolsAreOrdinary() {
        // `env` answers 127 for an executable it cannot find, which is the
        // ordinary case of a Mac without Homebrew rather than a failure.
        let failure = CommandFailure.notInstalled("brew")

        #expect(failure.errorDescription?.contains("brew") == true)
        #expect(failure.errorDescription?.contains("not installed") == true)
    }

    @Test("A real command runs, answers, and does not hang")
    func aRealCommandRuns() throws {
        // The only test that spawns a process, and it is chosen so that running
        // it changes nothing: `tmutil` is always installed, deleting a snapshot
        // dated 1999 cannot match anything, and doing it without root cannot
        // succeed even if it did. Every other command test injects a runner —
        // an earlier version of one did not, and cleared this Mac's preview
        // simulators when the suite ran.
        let result = try CommandRunner.execute(
            .tmutilDeleteSnapshot(name: "1999-01-01-000000")
        )

        #expect(result.command == .tmutilDeleteSnapshot(name: "1999-01-01-000000"))
        // Whether it refuses or reports nothing to do, it answered rather than
        // sitting on a prompt: that is what the null stdin is for.
        #expect(result.exitCode != 0 || result.output.isEmpty == false || result.succeeded)
    }

    @Test("The runner is injectable, so the executor can be driven without running anything")
    func runnerCanBeSubstituted() throws {
        let runner = CommandRunner { command in
            CommandResult(command: command, exitCode: 0, output: "pretended")
        }

        let result = try runner(.brewCleanup)

        #expect(result.succeeded)
        #expect(result.output == "pretended")
    }
}

/// The executor's half of the contract: a command finding runs its command, and
/// what happened lands in the receipt either way.
@Suite("Commands through the executor")
struct CommandExecutionTests {

    /// Records what the runner was asked to do, without running it.
    private final class CommandLog: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [KnownCommand] = []

        func record(_ command: KnownCommand) { lock.withLock { commands.append(command) } }
        var recorded: [KnownCommand] { lock.withLock { commands } }
    }

    @Test("A chosen command finding runs exactly once")
    func commandRunsOnce() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let one = try tree.file("previews/one.bin")
        let two = try tree.file("previews/two.bin")

        let ran = CommandLog()
        let executor = RemovalExecutor(
            definitions: [.fixture(root: tree.root)],
            runner: CommandRunner { command in
                ran.record(command)
                return CommandResult(command: command, exitCode: 0, output: "deleted 2 simulators")
            }
        )

        let receipt = executor.execute([
            .fixture(paths: [one, two], action: .command(.simctlDeletePreviews))
        ])

        // One command, not one per path.
        #expect(ran.recorded == [.simctlDeletePreviews])
        #expect(receipt.commandsRun.count == 1)
        #expect(receipt.outcomes == [.ran(command: .simctlDeletePreviews, output: "deleted 2 simulators")])
        // Attic did not measure what the tool freed, so it claims nothing.
        #expect(receipt.bytesTrashed == 0)
        // The files are the tool's business and are still where they were.
        #expect(FileManager.default.fileExists(atPath: one.path))
    }

    @Test("A command that fails is reported with what it said")
    func failingCommandIsReported() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("previews/one.bin")

        let receipt = RemovalExecutor(
            definitions: [.fixture(root: tree.root)],
            runner: CommandRunner { command in
                CommandResult(command: command, exitCode: 1, output: "Cannot connect to the Docker daemon")
            }
        ).execute([.fixture(paths: [file], action: .command(.dockerPrune(volumes: false)))])

        #expect(receipt.commandsRun.isEmpty)
        #expect(receipt.problems.count == 1)
        #expect(
            receipt.problems.first
                == .failed(
                    path: KnownCommand.dockerPrune(volumes: false).displayForm,
                    message: "Cannot connect to the Docker daemon"
                )
        )
    }

    @Test("A tool that is not installed is reported rather than throwing away the batch")
    func missingToolIsReported() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("previews/one.bin")

        let receipt = RemovalExecutor(
            definitions: [.fixture(root: tree.root)],
            runner: CommandRunner { _ in throw CommandFailure.notInstalled("brew") }
        ).execute([.fixture(paths: [file], action: .command(.brewCleanup))])

        #expect(receipt.wasAbandoned == false)
        #expect(receipt.problems.count == 1)
        #expect(receipt.problems.first?.loggedLine.contains("not installed") == true)
    }

    @Test("A command finding that is not offered never runs")
    func unofferedCommandsDoNotRun() throws {
        let tree = try FixtureTree()
        defer { tree.destroy() }
        let file = try tree.file("previews/one.bin")

        let ran = CommandLog()
        let executor = RemovalExecutor(
            definitions: [.fixture(root: tree.root)],
            runner: CommandRunner { command in
                ran.record(command)
                return CommandResult(command: command, exitCode: 0, output: "")
            }
        )

        let receipt = executor.execute([
            .fixture(paths: [file], action: .command(.brewCleanup), status: .detectOnly)
        ])

        #expect(ran.recorded.isEmpty)
        #expect(receipt.outcomes == [.revealed(path: file.path)])
    }
}
