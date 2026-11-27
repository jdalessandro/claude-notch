# Releasing

Everything runs from your Mac. There is no CI runner and no GitHub secret: hosted runners lack the macOS 27.3 SDK, and a
laptop-local flow needs only credentials you already have.

```bash
make prerelease   # signed + notarized build of HEAD, published as a prerelease (build-N); newest 15 kept
make release      # stable release of VERSION: tag vX.Y.Z, GitHub Release with CHANGELOG notes, Homebrew cask bump
scripts/release.sh --dry-run   # build, sign, notarize, verify; publish nothing
```

Cut a stable release: bump `VERSION`, add a `## [X.Y.Z]` section to `CHANGELOG.md`, merge and push, then `make release`.
The script checks everything up front (certificate, notary profile, `gh` login, clean and pushed tree, tag and changelog)
before the slow part, so a mistake fails in seconds.

## One command: `make ship`

```bash
make ship BUMP=minor     # patch | minor | major | X.Y.Z | current
scripts/ship.sh minor --plan   # show what would happen, change nothing
```

Add your notes under `## [Unreleased]` (or a `## [X.Y.Z] - Unreleased` heading) in `CHANGELOG.md` first. `ship` then:
bumps `VERSION`, dates that changelog section, opens and merges the bump PR (admin bypass, since `main` is protected),
runs `scripts/release.sh` (test, build, sign, notarize, dmg, GitHub Release, Homebrew cask) and finally checks every
channel: the dmg downloads and matches its checksum, `releases/latest` points at the new tag (what the curl installer
uses), and the tap's cask carries the new version and checksum. `BUMP=current` releases the version already in `VERSION`.

## One-time setup

1. **Developer ID certificate.** developer.apple.com ▸ Certificates ▸ *Developer ID Application* (Account Holder only). Create
   it from Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ *Developer ID Application*; it lands in your login keychain.
2. **Notary credentials**, stored once in the keychain (use an app-specific password from account.apple.com):
   ```bash
   xcrun notarytool store-credentials notchbot --apple-id <your apple id> --team-id <TEAM_ID>
   ```
3. **Signing team:** `echo <TEAM_ID> > .xcode-team` (already needed for `make bundle`).
4. **GitHub:** `gh auth login` with a token that can push to this repo and `homebrew-notchbot`.

If Live Activities turn out to need a Developer ID provisioning profile, download one per bundle id and run with
`APP_PROFILE=... WIDGET_PROFILE=... make release`.

## Later: automatic builds per merge

Needs a Mac that can run the macOS 27.3 SDK unattended (a rented or spare Mac as a self-hosted runner), or GitHub-hosted
runners once they ship that SDK. The script is already non-interactive apart from the keychain, so a workflow would
import the certificate, store the notary key and call `scripts/release.sh --prerelease`.
