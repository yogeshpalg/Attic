# Releasing Attic

Direct distribution, Developer ID signed and notarized. **Not** the Mac App Store: that
requires the sandbox, and a sandboxed Attic cannot enumerate or remove another app's
`~/Library/Caches` — the app's entire function is what the sandbox exists to prevent.

```
Tools/release.sh --check    # what is missing, without building anything
Tools/release.sh            # test, archive, sign, notarize, staple, package
```

---

## One-time setup

`--check` currently reports two things missing. Both are account-side, not code.

### 1. A Developer ID Application certificate

The keychain has *Apple Development* and *Apple Distribution*. Neither works for direct
distribution — a build signed with them is refused by Gatekeeper on someone else's Mac, which
is a confusing way to discover the problem.

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
3. **An account with Full Disk Access denied.** Sizes must be reported as floors ("at least"),
   the notice must appear, and the Open Full Disk Access button must go to the right pane.

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

## Still open

- **`DefinitionFeed.url` is `nil`**, so the update button does not render. It needs a URL that
  will stay stable, because it is compiled into every shipped build — changing it later takes an
  app update. Point it at a host you control regardless of what happens to any company name.
- **No in-app app updates.** There is no Sparkle yet, so a new version means downloading a new
  DMG. If that changes, the appcast URL has the same stability problem as the feed URL.
- **The repository folder is still named `Untitled Project`.** Harmless, and one command with
  Xcode closed: `mv "Untitled Project" Attic`.
