import Testing
import Foundation
@testable import Untitled_Project

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
        for category in Untitled_Project.Category.allCases {
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
