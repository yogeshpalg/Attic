# Releasing Attic

Direct distribution, Developer ID signed and notarized. **Not** the Mac App Store: that
requires the sandbox, and a sandboxed Attic cannot enumerate or remove another app's
`~/Library/Caches` — the app's entire function is what the sandbox exists to prevent.

```
Tools/release.sh --check    # what is missing, without building anything
Tools/release.sh            # test, archive, sign, notarize, staple, package
```

## Where 1.0 stands

**Built and notarized, matching the source; not published.**
`build/release/Attic-1.0.dmg` is version 1.0 **build 4** — 3.0 MB, notarized 2026-09-17
(submission `68da58ad-96f2-43dc-9c17-e42c74bfeb03`, *Accepted*) and stapled. `stapler validate`
passes on the image, and `spctl` accepts both the image and the app inside it as
`source=Notarized Developer ID`, `Developer ID Application: Yogesh Gahlot (5KP386UDP6)`.

Build 3 was the earlier notarized attempt and carried the old "everything goes to the Trash"
copy. It is superseded; nothing from it was published.

**Build 4 now trails the source too.** The Full Disk Access work — asking for the permission
rather than inferring it, the corrected pane identifier, and the relaunch step — landed after it
was notarized. Publishing needs `CURRENT_PROJECT_VERSION` at 5 and another run. Worth doing
*after* the three-machine checklist rather than before: item 3 exists to test exactly that work,
and finding a problem there means another build anyway.

`build/` is gitignored, so no DMG is in the repository and none should be added. Publishing
means attaching the artifact to a GitHub release.

**The remaining gate is the next section.** The suite passes — 343 tests across 59 suites — but
the Intel path has never run on Intel hardware, so *Before publishing: three machines* is a real
check rather than a formality.

---

## One-time setup

**Done on the current machine.** `--check` reports:

```
signing:        Developer ID Application: Yogesh Gahlot (5KP386UDP6)
notary:         keychain profile 'attic-notary' works

Everything needed is present.
```

Both items below are account-side, not code, so they are kept here for a new machine — or for
the day the certificate is lost, which is the expensive one.

### 1. A Developer ID Application certificate

*Apple Development* and *Apple Distribution* do not work for direct distribution — a build
signed with either is refused by Gatekeeper on someone else's Mac, which is a confusing way to
discover the problem.

Xcode → Settings → Accounts → select the team → Manage Certificates → **+** → **Developer ID
Application**. Then keep a backup: export it as a `.p12` with its private key and store it
somewhere safe. Losing it means every future release is signed by a different identity, which
resets Gatekeeper's trust and revokes users' Full Disk Access grants.

### 2. Notary credentials in the keychain

```
xcrun notarytool store-credentials attic-notary \
    --apple-id "<your Apple ID>" \
    --team-id 5KP386UDP6 \
    --password "<app-specific password>"
```

The app-specific password comes from appleid.apple.com → Sign-In and Security → App-Specific
Passwords. An App Store Connect API key works too and is better for CI.

The profile name `attic-notary` is what `Tools/release.sh` expects.

---

## Things that must never change after the first release

| Setting | Value | If it changes |
|---|---|---|
| Bundle identifier | `dev.yogesh.attic` | macOS treats the app as a different one: preferences, the lifetime counter, imported definitions and the Full Disk Access grant are all orphaned. |
| Signing team | `5KP386UDP6` | Gatekeeper shows a different "verified developer", and TCC revokes Full Disk Access because it is keyed to identity plus bundle id. |
| Definitions signing key | `~/.attic-signing/definitions.key` | Every already-published catalogue stops verifying. Rotating it needs a new app release carrying the new public key. |

The signing key is not in the repository and cannot be recovered. Back it up like a password.

---

## Versioning

`MARKETING_VERSION` is what people see (`1.0`); `CURRENT_PROJECT_VERSION` is the build number,
and must increase with every build submitted to the notary service. Bump the marketing version
for anything users would notice; bump only the build number for a re-notarized rebuild of the
same code.

## Why the hardened runtime is Release-only

Notarization requires it, and it enforces library validation — which refuses to load a test
bundle signed by a different team, so turning it on for Debug breaks `xcodebuild test` with a
misleading "could not load the test bundle" error. Release is the configuration that gets
archived, so that is where it lives. `Tools/release.sh` checks the exported app really carries
`flags=0x10000(runtime)`, which doubles as proof the archive used Release.

## Before publishing: three machines

The suite covers the engine; these cover the assumptions the suite cannot.

1. **An Intel Mac.** The build is universal and `SystemSupport` reports Intel correctly in
   tests, but the architecture path has never run on real Intel hardware. Check that the legacy
   notice appears and that no rule claims a location that is not there.
2. **A Mac with no Xcode and no Homebrew.** Most of the catalogue should report *rootMissing*
   and stay quiet. A first-run experience full of "found nothing" notices is a bug in the copy,
   not the engine.
3. **An account with Full Disk Access denied.** Five things, and the last two are the ones a
   passing suite cannot vouch for:
   - The notice appears **before** a scan proves anything — the probe is asked at launch, so
     "Attic does not have Full Disk Access" should be on screen without waiting for a rule to
     trip over a folder.
   - Sizes are reported as floors ("at least"), and whole rules report nothing rather than
     nothing being there.
   - The relaunch line is shown, not buried: a grant does not reach the running process.
   - **Open Full Disk Access lands on the Full Disk Access list**, not the top of System
     Settings. `FullDiskAccess.settingsURL` uses the identifier this release publishes
     (`com.apple.settings.PrivacySecurity.extension`), and a test pins it — but a stale
     identifier fails by opening the wrong pane rather than by erroring, so only a human can
     confirm this one.
   - **Quit and Reopen actually relaunches**, and the reopened copy reports the new state.

Also worth doing once on a clean account: confirm the first-run screen, the splash, all four
themes, and that the About panel's definitions line reads correctly.

## Publishing a definitions update

```
# 1. Start from the app's own export: About Attic → Export template…
# 2. Edit, then set formatVersion 1, a catalogueVersion higher than the last,
#    and an ISO 8601 `published` timestamp.
swift Tools/sign-definitions.swift sign catalogue.json ~/.attic-signing/definitions.key definitions.json

# 3. Check it the way the app will, before it goes anywhere.
swift Tools/sign-definitions.swift verify definitions.json "82RwraGm7yBM+NNV9F9wcrA5D2IRlwB1JqvPA83XfW8="

# 4. Upload to whatever DefinitionFeed.url points at.
```

`catalogueVersion` must go up. A correctly-signed older catalogue is refused, so a replayed file
cannot roll back a correction — and the same version *is* accepted, so a corrected republish
still lands.

`Tools/definitions/sample-catalogue.json` and `sample-signed.json` are a working pair.
`AtticTests/PublishedFormatTests` verifies that exact signed document against the key compiled
into the app, so a key rotation or an encoding change fails the suite rather than the field.

## Hosting the feed on Cloudflare

A good fit, because the catalogue is signed: **the CDN is untrusted transport.** Cloudflare
never holds the signing key, and the worst a compromised or misconfigured edge can do is serve
bytes the app refuses — a bad signature is rejected, an older `catalogueVersion` is rejected as
a downgrade, and anything that is not JSON is rejected outright. That is a very different risk
profile from a host that is trusted to be correct.

Two ways, both fine:

- **R2 + a custom domain.** A bucket with one object, exposed on `definitions.<your-domain>`.
  No code. Egress is free and the free tier is far beyond what a JSON file needs.
- **A Worker.** Worth it only if you want conditional responses later — serving different
  catalogues per macOS version, say, or per app version. The app already filters by both, so
  there is no reason to start here.

```
# once
wrangler r2 bucket create attic-definitions
# per publish
wrangler r2 object put attic-definitions/v1/definitions.json \
    --file definitions.json --content-type application/json \
    --cache-control "public, max-age=300"
```

Then point a custom domain at the bucket and set `DefinitionFeed.url` to
`https://definitions.<your-domain>/v1/definitions.json`.

Three things worth getting right:

- **Version the path, not the file.** `/v1/…` means a future incompatible format can be
  published at `/v2/…` while every already-shipped copy of Attic keeps reading `/v1/…` happily.
  Changing the URL later needs an app update; adding a new one does not.
- **Keep `max-age` short** (five minutes is plenty) and purge on publish. The app sets
  `reloadIgnoringLocalCacheData`, so it never serves its own stale copy — but the edge will
  happily hold an old object for as long as you tell it to.
- **A custom domain, not `*.r2.dev`.** The URL is compiled into every build, so it has to
  outlive whatever the storage behind it turns out to be.

The URL can be set **before anything is published**: a 404 or 410 is reported as
"No definitions update has been published yet", which is true, rather than as a failure. So this
can be deferred to whenever the first real catalogue is ready, and the only thing that has to be
decided early is the URL itself.

## Deliberately benched

- **The definitions update pathway.** `DefinitionFeed.url` is `nil`, so the update button does
  not render, and 1.0 ships that way on purpose. The signing, verification, downgrade-refusal
  and caching code is all written and under test — what is missing is a catalogue worth
  publishing. The rules describe paths that the next macOS release can move, rename or stop
  creating, and the feed reaches every installed copy at once, so the first published catalogue
  waits until it has been checked against that release. Until then the app uses the catalogue
  compiled into the build, which can only change when the build does.

  Turning it on is one line plus the steps under *Publishing a definitions update* above. Decide
  the URL before then rather than at that moment: it is compiled into every shipped build, so
  changing it later takes an app update. Point it at a host you control regardless of what
  happens to any company name.

## Still open

- **No in-app app updates.** There is no Sparkle yet, so a new version means downloading a new
  DMG. If that changes, the appcast URL has the same stability problem as the feed URL.
