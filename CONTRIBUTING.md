# Contributing to Attic

## Licensing, in one paragraph

Attic is MIT licensed. **By opening a pull request you agree that your contribution is
licensed under the same MIT terms**, and that you have the right to grant that — that the work
is yours, and not something your employer owns.

That sentence is the whole point of this section. Without it, every merged patch is owned by
whoever wrote it under no stated terms, and the project ends up unable to answer "what licence
is this under" for its own code. Stating it up front means there is nothing to untangle later:
what comes in is under the same licence as what goes out.

No CLA, no paperwork, no signing anything. The pull request is the agreement.

## What is most welcome

**Definitions.** The catalogue is the part that benefits most from people who know their own
tools. If you know where something hides gigabytes, that is a contribution nobody else can
make. See [DEFINITIONS.md](DEFINITIONS.md), and include in the pull request:

- the path, and how you confirmed it is what you say it is (`du -sh` output is ideal)
- the three sentences: what it is, what stops working, does it come back
- which macOS versions you checked it on, and whether the machine was Apple silicon or Intel

A definition asserting something about a folder nobody measured is the one kind of contribution
that can cost somebody their data, so evidence matters more than volume here.

**Bug reports with a reproduction.** Especially anything where a size was wrong, a rule found
nothing it should have found, or a row's explanation did not match what actually happened.

## What will be turned down

- **A rule that cannot explain itself.** The three sentences are not documentation, they are the
  product. A rule without them has nothing to offer a person deciding.
- **Grading something `safe` that costs a rebuild or a download.** That grade means "no decision
  required beyond ticking it". Everything else is `checkFirst`.
- **Widening what the engine can do to make a rule work.** The gates — containment, denylist,
  re-verification, Trash rather than delete — are the reason this app can be trusted with a
  disk. A rule that needs one of them relaxed is a rule that does not ship.
- **Anything that makes the app claim more than it did.** "Freed" instead of "moved to the
  Trash", a progress bar with nothing behind it, a total that includes bytes no operation would
  remove. The app's one distinguishing feature is that its numbers are true.

## Working on it

```
open Attic.xcodeproj      # Xcode 26 or later
xcodebuild test -project Attic.xcodeproj -scheme Attic -destination 'platform=macOS,arch=arm64'
```

The tests are the specification. Each suite's doc comment names the invariant it defends and why
failing it matters — read those before changing engine behaviour, because several of them exist
because something went wrong once.

New behaviour comes with a test. New *safety* behaviour comes with a test that fails before the
change, so the thing being defended is demonstrably defended.

## Style

Match the surrounding code: four-space indentation, no abbreviations in names, comments that
explain *why* rather than restating the line beneath them. Comments earn their place by saying
something the code cannot — a constraint discovered the hard way, a rejected alternative, a
reason a cautious-looking default is the safe one.

## If you fork it

Keep the copyright notice — it is the only thing MIT asks, and the app carries it in
About Attic so a binary you distribute honours it without you doing anything. Beyond that: sell
it, rename it, strip it down. That is what the licence is for.
