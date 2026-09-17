# Attic definitions

A **definition** is one rule: a place on the Mac, what lives there, and what happens if it
goes. Attic ships a compiled catalogue, can fetch a signed official one, and reads a file of
your own. Nothing in the app hardcodes a path — all of it is data, which is why you can add to
it without touching Swift.

---

## Authoring your own

1. **Attic → About Attic → Export template…** writes the built-in catalogue as JSON. That is
   your starting point: ~25 worked examples, not a schema to guess at.
2. Edit it. Keep the rules you want, delete the rest, add your own.
3. **Import…** in the same panel. Rules apply to the next scan.

Your file lives at `~/Library/Application Support/dev.yogesh.attic/custom-definitions.json`.
Editing it directly works too — the limits below are enforced when it is read, not only when
it is imported.

A file is refused whole, with the offending rule ids named, if any rule:

| Refusal | Why |
|---|---|
| runs a command | Commands are code execution. "Import these definitions" must never become "run this for me" — even from the allowlist. |
| shares an id with another rule in the file | Ids are finding-id prefixes; duplicates silently merge two rules in the UI. |
| is missing any of the three explanation sentences | A rule that cannot explain itself has no business offering a checkbox. |
| has a `/` in its `displayName` | Names are shown to people. Paths belong in `root`. |
| declares a `formatVersion` this build does not read | Better refused than half-understood. |

### What an imported rule is allowed to do

An imported rule may arrive `active` — offered, with a checkbox — only if it is all of:

- `action: trash`
- `privilege: user`
- `grade: safe` or `checkFirst`
- not `holdsAuthoredWork`

Anything wider arrives `detectOnly`: found, measured, explained, no checkbox. It is **demoted,
not dropped** — a refused rule that vanished would leave you with a gigabyte you cannot see and
no explanation.

`holdsAuthoredWork` is **sticky per rule id**. If a built-in rule carries it, your override
cannot remove it. Otherwise a file could re-grade the coding-assistant transcripts rule as
`safe` and quietly delete the history behind every project you have.

### The gates your rule still passes through

Authoring a rule does not widen what the engine will do:

1. **Containment** — every matched path is resolved with `realpath(3)` and must still be inside
   the declared root. A symlink pointing out is refused and reported.
2. **Denylist** — `~/Documents`, device backups, Xcode archives and friends are refused in both
   directions, whatever a rule says.
3. **Re-verification at removal time** — the plan re-runs both gates and re-measures immediately
   before moving anything.
4. **Trash, not delete** — `trash` means `FileManager.trashItem`. Emptying it is the user's act.

---

## The shortest rule that works

Seven fields are required. Everything else has a cautious default, so a hand-written rule can
be this short:

```json
{
  "formatVersion": 1,
  "rules": [
    {
      "id": "mine.tool-cache",
      "category": "cachesAndLogs",
      "displayName": "My tool's cache",
      "root": { "home": { "_0": "Library/Caches/com.example.mine" } },
      "match": { "wholeRoot": {} },
      "action": { "trash": {} },
      "explanation": {
        "whatThisIs": "A cache my tool writes while building.",
        "whatStopsWorking": "Nothing. It is rebuilt the next time the tool runs.",
        "doesItComeBack": "Yes, on the next build."
      }
    }
  ]
}
```

Those seven are required because getting any of them wrong would make the rule something other
than what you meant: `root` and `match` decide *what is matched*, `action` decides *what
happens to it*, and the three sentences are the whole promise of the app. A typo in any of them
fails loudly and names the field — `rule 1 is missing 'root'` — rather than quietly becoming
something else.

Note what the defaults give you: an ungraded rule is **`checkFirst`**, never `safe`, so a rule
nobody graded is never swept up by "Select safe".

Unknown keys are ignored, so you can leave yourself notes in the file. The `_help` key that
exported templates carry is one of those — documentation, not data.

## Rule fields

Required: `id`, `category`, `displayName`, `root`, `match`, `action`, `explanation`.
Everything else is optional, with the default in brackets.

| Field | Meaning |
|---|---|
| `id` | Stable, dotted. Prefix of every finding id it produces. |
| `minAppVersion` | Rules may ship ahead of the app that understands them. [`1.0`] |
| `minOSVersion` / `maxOSVersion` | Inclusive, compared numerically (`15.10` is newer than `15.9`). Set **only** where a location actually changed between releases. |
| `architecture` | `appleSilicon` or `intel`, for the rare location that only exists on one. Left empty otherwise — a cache is a cache on either machine. No shipped rule sets it, and a test asserts that. |
| `category` | Sidebar grouping. |
| `displayName` | Shown to people. No paths. |
| `root` | `home("Library/Caches/thing")` or `absolute("/Library/Updates")`. |
| `match` | `wholeRoot`, `immediateChildren`, `namedChildren([…])`, `childrenWithPrefix([…])`, `filesWithExtension("ipsw")` (recursive), `downloadedCloudFiles`, `orphanedSupport(application|tool)`. A closed set, deliberately — there is no glob engine to get subtly wrong. |
| `exclude` | `pathComponent`, `fileExtension`, `nameSuffix`, `bundleIdentifierNames`. [none] |
| `grouping` | `single`, `perMatch`, `perOwner`. [`single`] |
| `retention` | `none`, `excludeModifiedWithin(days:)`, `keepNewestPerLeadingComponent`. Whatever is withheld is **reported**, never silently dropped. [`none`] |
| `action` | `trash`, `revealOnly`, `evictCloudCopy`, `command(…)` (built-in only). |
| `privilege` | `user`, or `administrator` — Attic never escalates, so an administrator rule degrades to Reveal in Finder. [`user`] |
| `grade` | `safe`, `checkFirst`, `keep`. [`checkFirst`] |
| `holdsAuthoredWork` | True when nothing regenerates what this matches. [`false`] |
| `status` | `active` or `detectOnly`. [`active`] |
| `explanation` | Three sentences: what this is, what stops working, does it come back. |

`root` pointing somewhere that does not exist is not an error: the rule reports
`rootMissing` and finds nothing. That is how one catalogue covers Macs with and without Xcode,
Homebrew, Docker or a Rust toolchain.

---

## Official catalogues

Fetched catalogues are Ed25519-signed and refused outright without a valid signature — and the
cached copy is re-verified on every read, because the cache file is user-writable and deserves
no more trust than the network.

```json
{
  "payload":   "<base64 of the UTF-8 JSON of a CataloguePayload>",
  "signature": "<base64 Ed25519 signature over those exact bytes>"
}
```

The payload travels base64-encoded because a signature covers *bytes*, and re-encoding a
decoded object does not reproduce them — key order, whitespace and date formatting all drift.

```json
{ "formatVersion": 1, "catalogueVersion": 12, "published": "2026-09-16T00:00:00Z", "rules": [ … ] }
```

`catalogueVersion` is monotonic. An older catalogue is refused even when correctly signed, so a
replayed file cannot roll back a correction. The same version *is* accepted, so a corrected
republish still lands.

Signed rules run under the same limits as imported ones, plus one difference: they may carry
`command` actions, which arrive `detectOnly` until a release of the app promotes them.

A build with no signing key refuses everything, which is the correct failure — "no key" must
never mean "accept anything", and there is a test pinning that. This build does carry one, and
`AtticTests/PublishedFormatTests` checks a catalogue signed by it against the shipping verifier,
so a key rotation or an encoding change fails the suite rather than the field.

---

## Verified systems

Apple silicon began at **macOS 11 Big Sur** (M1, November 2020), so every release below runs on
it. **macOS 26 Tahoe is the last release Apple supports on Intel**; **macOS 27 Golden Gate is
Apple silicon only**.

| Release | Name | Attic |
|---|---|---|
| 11 | Big Sur | Below deployment target — cannot launch |
| 12 | Monterey | Below deployment target — cannot launch |
| 13 | Ventura | Below deployment target — cannot launch |
| 14 | Sonoma | Below deployment target — cannot launch |
| 15 | Sequoia | **Verified** |
| 26 | Tahoe | **Verified** |
| 27 | Golden Gate | **Verified** (development machine) |

`SupportedSystems.testedFloor` / `testedCeiling` hold that range. Raise the ceiling after
checking the catalogue's paths on the new release — **not** when the release ships.

Outside the range, or on Intel, Attic says so in the notices above the findings rather than
letting a rule that found nothing read as "there is nothing here". The cost of Attic not knowing
a location is always a rule that finds nothing — never a rule that removes the wrong thing.

### Findings from the per-path review

- **Stable across 15 → 27**, verified on disk: `~/Library/Developer/Xcode/**` (DerivedData,
  iOS DeviceSupport, Previews, DocumentationCache), `~/Library/Caches/**`, `~/.cache`,
  `~/Library/Developer/CoreSimulator/**`, `/Library/Updates`,
  `~/Library/Mobile Documents/com~apple~CloudDocs`. None need OS bounds.
- **Device firmware is per-device-kind.** macOS keeps sibling folders — `iPhone Software
  Updates`, `iPad Software Updates`, `Apple TV Software Updates` — under `~/Library/iTunes`,
  and that folder survived the death of iTunes. A rule aimed at the iPhone folder misses every
  other device. Attic roots at `~/Library/iTunes` and recurses for `.ipsw`.
- **Xcode-version, not macOS-version**: `~/Library/Developer/Xcode/CodingAssistant` (Xcode 26+)
  and the move of simulator runtimes to `/Library/Developer/CoreSimulator/Profiles/Runtimes`
  (Xcode 14+). `rootExists` handles both; no OS bound belongs on them.
- **Rosetta AOT cache** — `/private/var/db/oah`, Apple silicon only, present since macOS 11.
  Owned by `_oahd` and SIP-protected: unreadable and undeletable without disabling SIP, and it
  is forensically meaningful. Deliberately no rule. The supported reset is reinstalling Rosetta.
- **Apple Intelligence models** — `/System/Library/AssetsV2/com_apple_MobileAsset_UAF_*`,
  measured at **6.0 GB** on the development Mac (Siri Understanding 2.7 GB, Spatial Photos
  943 MB, Linguistic Data 650 MB, Translation 632 MB, speech recognition 408 MB, and a tail).
  The whole `AssetsV2` tree is 27 GB, but only the UAF families are models, so only those are
  counted. On the read-only system volume and SIP-protected: **no cleaner can delete this**,
  and any that claims to is lying. Apple silicon only — Apple Intelligence requires it.

  Attic shows this under *Managed by macOS*: measured, broken down by family, never selectable,
  with a link to `x-apple.systempreferences:com.apple.Siri-Settings.extension` — the only
  supported control. That identifier was read out of this Mac's own System Settings binary,
  because the panes were reorganised in macOS 26 and again in 27 and a stale identifier
  silently opens System Settings at the top level instead of failing.
- **`/macOS Install Data`** exists only mid-upgrade, and `/Library/Updates` is root-owned. Both
  are `revealOnly`: Attic does not escalate, and a `trash` action it cannot perform would be a
  lie in the UI.

Sources for the version and Apple-silicon specifics: Apple's
[macOS version support page](https://support.apple.com/en-us/109033),
[Macworld's compatibility list](https://www.macworld.com/article/673697/what-version-of-macos-can-my-mac-run.html),
Howard Oakley on
[Rosetta 2 and OAH](https://eclecticlight.co/2021/01/22/running-intel-code-on-your-m1-mac-rosetta-2-and-oah/),
and the Apple Intelligence storage write-ups
([iDownloadBlog](https://www.idownloadblog.com/2026/08/04/remove-apple-intelligence-files-mac/),
[GitHub guide](https://github.com/tejyash/delete-apple-intelligence-macos)).
