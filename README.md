# Attic

A disk-space app for macOS that tells you what something is before it offers to remove it.

Attic finds the caches, build leftovers, downloaded installers, device firmware and support
files from apps you deleted months ago — then, for each one, says three things: **what this
is**, **what stops working** if it goes, and **does it come back**. Nothing is ticked for you.
Everything it removes goes to the Trash, so a wrong choice is a drag back out.

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

## Safety

Three gates run before any path is offered, and again immediately before anything moves:

1. **Containment** — every match is resolved with `realpath(3)` and must still sit inside the
   rule's declared root. A symlink pointing outside is refused and reported on screen.
2. **Denylist** — `~/Documents`, device backups, Xcode archives and similar are refused in both
   directions, whatever a rule claims.
3. **Re-verification** — the plan re-runs both gates and re-measures just before acting, so a
   scan that went stale cannot become a removal.

**Protect my work** is on by default. Rules matching authored work — coding-assistant
transcripts, local artefacts that exist nowhere else — are found, measured and explained but
never offered while it is on. That protection is sticky: no definitions update and no imported
file can take it off a rule that has it.

## Definitions

Every location Attic knows about is data, not code. The catalogue ships compiled in, can be
updated from a signed feed, and you can write your own — see **[DEFINITIONS.md](DEFINITIONS.md)**
for the format, the limits on imported rules, and why those limits exist.

Export a starter file from **About Attic → Export template…**, edit it, import it back.

## Building

```
open Attic.xcodeproj      # Xcode 26 or later
```

Tests: ⌘U, or

```
xcodebuild test -project Attic.xcodeproj -scheme Attic -destination 'platform=macOS,arch=arm64'
```

305 tests across 51 suites. They are the specification: each suite's doc comment names the
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
