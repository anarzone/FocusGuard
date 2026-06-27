# Releasing FocusGuard

Releases are cut automatically by `.github/workflows/release.yml` (push to `main` under
app paths → auto-bump patch → build, sign, GitHub Release, publish Sparkle appcast, bump the
Homebrew tap). `scripts/release.sh <version>` does the same thing locally.

This doc covers the **Sparkle in-app update** machinery and the one-time setup it needs.

## How updates flow

1. CI builds + signs `FocusGuard.app`, zips it, and attaches the zip to a GitHub Release.
2. `scripts/generate_appcast.sh` EdDSA-signs the zip and renders `appcast.xml`.
3. CI publishes `appcast.xml` to the `gh-pages` branch.
4. GitHub Pages serves it at **https://anarzone.github.io/FocusGuard/appcast.xml** —
   the `SUFeedURL` baked into the app (see `project.yml`).
5. The running app (Sparkle) fetches the feed, compares versions, verifies the zip against
   `SUPublicEDKey`, strips quarantine, and installs.

Sparkle compares the appcast's `<sparkle:version>` (the build number) against the installed
app's `CFBundleVersion`. Both the build and the appcast take that number from the **same**
source per release: `github.run_number` in CI, `git rev-list --count HEAD` locally — so they
always agree within a release flow.

## One-time setup

These must be done once before the first Sparkle-enabled release.

### 1. EdDSA signing key

The key pair was generated with Sparkle's `generate_keys`. The **public** key is already in
`project.yml` (`SUPublicEDKey`). The **private** key is stored in the release machine's login
keychain (used by `scripts/release.sh`).

For CI, export the private key and store it as a repo secret:

```sh
# from a build that has Sparkle resolved:
SU_BIN=build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin
"$SU_BIN/generate_keys" -x sparkle_private_key.pem   # writes the base64 private key
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_private_key.pem
rm sparkle_private_key.pem                            # don't leave it on disk / never commit it
```

> ⚠️ Treat the private key like a password. Anyone with it can sign updates your users will
> auto-install. It is never committed; CI reads it only from the `SPARKLE_ED_PRIVATE_KEY`
> secret. To rotate, run `generate_keys` again, update `SUPublicEDKey` in `project.yml`, and
> reset the secret — but note older installs trust the old key until they update once.

### 2. Enable GitHub Pages

In the repo **Settings → Pages**: set **Source = Deploy from a branch**, **Branch =
`gh-pages` / root**. The first release will create the `gh-pages` branch if it doesn't exist;
after that, confirm `https://anarzone.github.io/FocusGuard/appcast.xml` resolves.

### 3. Homebrew cask: `auto_updates true`

Because Sparkle updates the app in place, tell Homebrew the app self-updates so `brew` won't
fight it. In the **`anarzone/homebrew-tap`** repo, add to `Casks/focusguard.rb`:

```ruby
auto_updates true
```

(The release flow only bumps `version` + `sha256` in that file; add this line once by hand.)

## Required GitHub secrets

See the header of `.github/workflows/release.yml` for the full list. Sparkle adds one:

| Secret | Purpose |
| --- | --- |
| `SPARKLE_ED_PRIVATE_KEY` | base64 EdDSA private key that signs the appcast |

## Notes / future

- **Notarization is not done.** The app is signed with a free-team *Apple Development* cert,
  which can't be notarized (that needs a paid Developer ID). Sparkle still installs updates
  (it verifies its own EdDSA signature and strips quarantine), but if you later enroll in the
  paid program, switch to *Developer ID Application* + notarization for cleaner Gatekeeper
  behavior on fresh installs.
- The appcast carries a single newest `<item>`, which is all Sparkle needs to detect an
  update. If you want delta updates or a full version history, switch the pipeline to
  Sparkle's `generate_appcast` over a directory of release zips.
