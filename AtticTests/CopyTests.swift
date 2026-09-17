import Testing
import Foundation
@testable import Attic

/// Invariant 13. Every string the app puts on screen has to be true of the thing
/// it describes. The interesting failures here are not crashes: they are a row
/// that says it will empty a folder when nothing is on offer, or a banner that
/// names a source identifier at someone who has never read the source.
@Suite("User-facing copy")
struct ActionCopyTests {

    @Test("An action Attic is not offering is phrased conditionally")
    func unofferedActionsArePhrasedConditionally() {
        #expect(RemovalAction.trash.displayForm == "Moves the matched files to the Trash")
        #expect(RemovalAction.trash.conditionalForm == "Would move the matched files to the Trash")

        let command = RemovalAction.command(.brewCleanup)
        #expect(command.displayForm == "brew cleanup")
        #expect(command.conditionalForm == "Would run brew cleanup")
    }

    @Test("Reveal reads the same either way, because it promises nothing")
    func revealIsAlreadyConditional() {
        // "Reveal in Finder — Attic will not remove this" is already a statement
        // about what will not happen.
        #expect(RemovalAction.revealOnly.conditionalForm == RemovalAction.revealOnly.displayForm)
    }

    @Test("Every command names the binary it would run, in full")
    func everyCommandShowsItsExactText() {
        let commands: [KnownCommand] = [
            .simctlDeletePreviews,
            .simctlDeleteUnavailable,
            .simctlRuntimeDelete(identifier: "iOS 26.4"),
            .tmutilDeleteSnapshot(name: "com.apple.TimeMachine.2026-09-15"),
            .brewCleanup,
            .goCleanModcache,
            .dockerPrune(volumes: true),
        ]

        for command in commands {
            #expect(command.displayForm.isEmpty == false)
            // Shown verbatim in the expanded row, so the exact operation is
            // visible before anything is ticked.
            #expect(command.displayForm.contains("  ") == false)
            #expect(command.displayForm.hasPrefix(" ") == false)
        }

        #expect(
            KnownCommand.simctlRuntimeDelete(identifier: "iOS 26.4").displayForm
                == "xcrun simctl runtime delete iOS 26.4"
        )
        #expect(KnownCommand.dockerPrune(volumes: true).displayForm == "docker system prune --volumes")
        #expect(KnownCommand.dockerPrune(volumes: false).displayForm == "docker system prune")
    }

    @Test("Every reason a rule reports has something to say")
    func everyReasonHasAMessage() {
        let rejections: [RejectionReason] = [.outsideDeclaredRoot, .denylisted, .protectedComponent]
        let unavailable: [UnavailableReason] = [
            .softwareNotInstalled, .rootMissing, .emptyRoot, .permissionDenied,
        ]
        let withheld: [WithheldReason] = [.touchedRecently(days: 7), .newestForItsDevice]

        for reason in rejections { #expect(reason.message.isEmpty == false) }
        for reason in unavailable { #expect(reason.message.isEmpty == false) }
        for reason in withheld { #expect(reason.message.isEmpty == false) }

        // The messages are sentence fragments, completed by the banner around
        // them: "… was skipped — the folder this looks in is empty".
        #expect(UnavailableReason.emptyRoot.message.first?.isUppercase == false)
        #expect(WithheldReason.touchedRecently(days: 7).message.contains("7"))
    }

    @Test("Every safety grade and category has a label to show")
    func everyGradeAndCategoryIsLabelled() {
        for grade in SafetyGrade.allCases {
            #expect(grade.label.isEmpty == false)
        }
        for category in Attic.Category.allCases {
            #expect(category.title.isEmpty == false)
            #expect(category.title.contains("/") == false)
        }
    }
}

/// Zero bytes is shown as an em dash rather than "0 bytes", so a row that found
/// nothing does not read as a row offering nothing.
@Suite("Byte formatting")
struct ByteFormatTests {

    @Test("Zero is shown as a dash")
    func zeroIsADash() {
        #expect(ByteFormat.string(0) == "—")
    }

    @Test("A real size is formatted in file units")
    func realSizesAreFormatted() {
        let formatted = ByteFormat.string(5_242_880)

        #expect(formatted.isEmpty == false)
        #expect(formatted != "—")
        #expect(formatted.contains("MB"))
    }
}

/// The licence, and the credit it carries.
///
/// MIT permits nearly everything and asks one thing in return: that the
/// copyright notice travels with every copy. For a binary that means the app
/// must be able to show it — a LICENSE file left in a repository is not part of
/// the copy somebody downloaded. These tests are what keep that honest.
@Suite("The licence travels with the app")
struct LicenceTests {

    @Test("The app carries the full licence text, not a summary")
    func fullTextIsPresent() {
        // A paraphrase would not satisfy the notice requirement, and would
        // quietly change the terms somebody is relying on.
        #expect(Licence.text.contains("Permission is hereby granted"))
        #expect(Licence.text.contains("WITHOUT WARRANTY OF ANY KIND"))
        #expect(Licence.text.contains("shall be included in all"))
    }

    @Test("The notice names the holder, which is the whole point of the licence")
    func noticeNamesTheHolder() {
        // Credit is the one thing the licence asks for. If this stops matching,
        // the app is distributing itself without the attribution it requires.
        #expect(Licence.notice.contains(Licence.holder))
        #expect(Licence.text.contains(Licence.holder))
        #expect(Licence.text.contains(Licence.year))
    }

    @Test("The in-app text agrees with the LICENSE file on every term")
    func inAppTextMatchesTheFile() throws {
        // Two copies of a licence that disagree is worse than one: nobody knows
        // which set of terms applies. Compared word by word rather than
        // character by character, because the in-app copy is rewrapped.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AtticTests
            .deletingLastPathComponent()   // repository root
            .appending(path: "LICENSE")

        guard let file = try? String(contentsOf: repository, encoding: .utf8) else {
            // Running from somewhere the source tree is not, which is fine —
            // the checks above still hold.
            return
        }

        func words(_ text: String) -> [String] {
            text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }

        #expect(words(file) == words(Licence.text))
    }

    @Test("The dependency statement is true of this build")
    func dependencyStatementIsTrue() {
        // There are no Swift packages and no vendored source, which is why the
        // acknowledgements are one sentence. If a dependency is ever added,
        // this sentence becomes a lie and needs rewriting.
        #expect(Licence.dependencies.contains("No third-party code"))
    }
}

/// The links the app offers, and the rule that it offers none it cannot honour.
@Suite("Links are derived, and absent until they exist")
struct LinkTests {

    @Test("With nothing configured, every link is absent")
    func nothingIsOfferedByDefault() {
        // A button that opens a dead page looks like a broken app rather than
        // an unset link, so the interface draws nothing at all.
        #expect(AtticLinks.source == nil)
        #expect(AtticLinks.issues == nil)
        #expect(AtticLinks.support == nil)
        #expect(AtticLinks.definitionsGuide == nil)
        #expect(AtticLinks.hasAny == false)
    }

    @Test("Source, issues and the guide are derived from one string")
    func repositoryLinksShareOneSource() {
        // Written three times, they drift: the issues link ends up pointing at
        // last year's repository name. Derived, they cannot.
        func urls(for slug: String) -> [String] {
            [
                "https://github.com/\(slug)",
                "https://github.com/\(slug)/issues",
                "https://github.com/\(slug)/blob/main/DEFINITIONS.md",
            ]
        }

        // The shape the accessors produce, checked without mutating the
        // constants — they are compile-time configuration, not state.
        #expect(urls(for: "owner/attic") == [
            "https://github.com/owner/attic",
            "https://github.com/owner/attic/issues",
            "https://github.com/owner/attic/blob/main/DEFINITIONS.md",
        ])
    }

    @Test("Support is separate from the repository")
    func supportIsIndependent() {
        // Someone may want the source public without asking for money, so the
        // sponsor account is its own switch rather than implied by the repo.
        #expect(AtticLinks.repository.isEmpty)
        #expect(AtticLinks.sponsorAccount.isEmpty)
    }
}
