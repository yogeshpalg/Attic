# Attic

A disk-space app for macOS that tells you what something is before it offers to remove it.

Attic finds the caches, build leftovers, downloaded installers, device firmware and support
files from apps you deleted months ago — then, for each one, says three things: **what this
is**, **what stops working** if it goes, and **does it come back**. Nothing is ticked for you.
Almost everything it removes goes to the Trash, so a wrong choice is a drag back out — the two
exceptions are named below rather than glossed over.

macOS 15 or later, Apple silicon or Intel.

---

## Why another cleaner

Most of them tell you a number and ask you to trust it. This one is built the other way round:

- **Nothing is pre-selected.** Removal is always an act you performed, item by item.
- **"Moved to the Trash", never "freed".** Emptying the Trash is your decision, so the
  lifetime counter does not take credit for space that has not actually come back.
- **Nothing is silently dropped.** When a rule withholds a match — too recently used, newest
  firmware for its device — the app says so and says how much. "Found nothing" must never
  quietly mean "hid 1.15 GB".
- **Sizes you can check.** Beside the headline figure is a link that copies a `du -sch` over
  every path in view, so you can verify the number against the system rather than believe it.
- **It admits what it cannot do.** The on-device Apple Intelligence and Siri models are several
  gigabytes on a modern Mac and no app can delete them — they are on the read-only system
  volume under SIP. Attic measures them, explains them, and points at the one supported
  control. Any cleaner claiming to remove that space is lying about where it went.
- **It never escalates.** Anything needing administrator rights degrades to *Reveal in Finder*
  rather than installing a privileged helper.

## What it can actually remove

The shipped catalogue is **27 rules**, and what each one is permitted to do is part of the rule
rather than a decision made at the last moment:

| What happens | Rules | What that means |
|---|---|---|
| Moved to the Trash | 23 | `FileManager.trashItem`. Recoverable until you empty it. |
| Reveal in Finder only | 2 | An interrupted macOS install and downloaded system updates. Both are root-owned, and Attic does not escalate — so it shows you rather than pretending it can act. |
| Local copy evicted | 1 | iCloud Drive files already in iCloud. Nothing is deleted: the file stays in the cloud and downloads again on demand. |
| Deleted by a command | 1 | SwiftUI preview simulators, via `xcrun simctl --set previews delete all`. There is no Trash for these — the next preview you open rebuilds them. |

So the Trash is the route for the large majority, but **not all of it**, and the two rules that
do not use it say so on the row. Of the 27, sixteen are graded *safe* and eleven *check first*;
three hold authored work and are withheld entirely while **Work protected** is on.

What Attic cannot remove at all, and says so: anything on the read-only system volume under
SIP. The on-device Apple Intelligence and Siri models are the big one — measured, explained,
never selectable.

## Safety

Three gates run before any path is offered, and again immediately before anything moves:

1. **Containment** — every match is resolved with `realpath(3)` and must still sit inside the
   rule's declared root. A symlink pointing outside is refused and reported on screen.
2. **Denylist** — `~/Documents`, device backups, Xcode archives and similar are refused in both
   directions, whatever a rule claims.
3. **Re-verification** — the plan re-runs both gates and re-measures just before acting, so a
   scan that went stale cannot become a removal.

The toolbar toggle reading **Work protected** — that is its label when on; it says
**Protection off** when off — starts on. Rules matching authored work, such as coding-assistant
transcripts and local artefacts that exist nowhere else, are found, measured and explained but
never offered while it is on. That protection is sticky: no definitions update and no imported
file can take it off a rule that has it.

## Definitions

Every location Attic knows about is data, not code. The catalogue ships compiled in and you can
write your own — see **[DEFINITIONS.md](DEFINITIONS.md)** for the format, the limits on imported
rules, and why those limits exist.

There is also a signed-feed pathway for official updates, built and tested but **switched off in
this release**: no catalogue has been published, so the app uses the one compiled into the build
and shows no update button. The reason is in [RELEASING.md](RELEASING.md) — rules name paths a
new macOS can move, and a published catalogue reaches every installed copy at once.

Export a starter file from **About Attic → Export template…**, edit it, import it back.

## Building

```
open Attic.xcodeproj      # Xcode 26 or later
```

Tests: ⌘U, or

```
xcodebuild test -project Attic.xcodeproj -scheme Attic -destination 'platform=macOS,arch=arm64'
```

329 tests across 56 suites. They are the specification: each suite's doc comment names the
invariant it defends and why failing it matters.

Releasing is documented in **[RELEASING.md](RELEASING.md)**.

## Licence

MIT — see [LICENSE](LICENSE). Copyright © 2026 Yogesh Gahlot.

Use it, change it, ship it, charge for it. The one thing the licence asks is that the copyright
notice travels with every copy, which is why the app carries the full text in **About Attic →
Read it** rather than leaving it behind in this repository. A binary you distribute honours the
terms without you doing anything.

Contributions are welcome and covered by the same licence — see [CONTRIBUTING.md](CONTRIBUTING.md).
Definitions are the most useful thing you can send.

### Name and mark

MIT is a copyright licence and says nothing about names, so this does: the licence covers the
**source**. The name *Attic* and the app's mark are not part of that grant — fork it and sell it,
under its own name, without implying the author endorses the result.

That is not a restriction on forking. It is the same thing the copyright notice asks for: that
credit stays attached to who did what.
