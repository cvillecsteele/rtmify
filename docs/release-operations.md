# Release Operations

This is the operator runbook for producing RTMify release artifacts, staging Windows payloads, packaging Windows installers in GitHub Actions, and publishing the final signed assets.

## Scope

This workflow spans two repositories:

- `cvillecsteele/rtmify`
  Contains the product code, `release.sh`, `tools/publish.py`, validation assets, and the GitHub Actions workflows.
- `cvillecsteele/rtmifysite`
  Hosts `rtmify.io` on GitHub Pages and publishes the checked-in download manifest at `public/downloads/latest.json`.

Local signing remains the trust boundary:

- macOS signing and notarization happen locally
- Windows payload signing happens locally
- Windows final installer signing happens locally
- GitHub Actions only runs Inno Setup on a Windows runner

## Artifact Contract

`release.sh` writes the raw release directory:

- `bin/`
  - `rtmify-license-gen`
  - `rtmify-trace`
  - `rtmify-live`
- `macos/`
  - `RTMify Trace.app`
  - `RTMify Live.app`
- `windows/`
  - `rtmify-trace.exe`
  - `RTMify Live.exe`
  - `rtmify-live.exe`
- `linux/`
  - `rtmify-trace`
- `validation/`
  - validation package outputs
- `manifest.json`

`tools/publish.py package` produces:

- macOS:
  - `packages/macos/RTMify_Trace_<version>.dmg`
  - `packages/macos/RTMify_Live_<version>.dmg`
- Windows stage output:
  - `packages/windows/RTMify_Windows_Payloads_<version>.zip`
- Windows final output:
  - `packages/windows/RTMify_Trace_Installer_<version>.exe`
  - `packages/windows/RTMify_Live_Installer_<version>.exe`
- Linux:
  - `packages/linux/*.tar.gz`
- metadata:
  - `checksums.txt`
  - `package-manifest.json`

Windows package state is explicit in `package-manifest.json`:

- stage run:
  - `status: "payloads_signed"`
  - `payload_zip` present
  - `installers: []`
- finalize run:
  - `status: "finalized"`
  - `payload_zip` still present
  - `installers` populated

## Required Local Tooling

### Common

- `python3` (3.10+)
- `gh`
- `git`

### macOS signing and notarization

- `codesign`
- `xcrun notarytool`
- `xcrun stapler`
- a valid `Developer ID Application` certificate in the login keychain
- App Store Connect Team API key for notarization

Recommended Apple setup now that RTMify is on the organization account:

1. Create a `Developer ID Application` certificate for `Iron Brothers Ventures LLC`.
2. Import it into the macOS login keychain.
3. Create an App Store Connect team API key for notarization.
4. Store the notary credentials in the keychain once:

```bash
xcrun notarytool store-credentials RTMify-Notary \
  --key "$HOME/.rtmify/secrets/AuthKey_ABCDEFGHIJ.p8" \
  --key-id "ABCDEFGHIJ" \
  --issuer "00000000-0000-0000-0000-000000000000" \
  --validate
```

That gives `tools/publish.py` a stable local credential handle instead of requiring the raw key path on every release.

Environment variables:

- `APPLE_SIGNING_IDENTITY`
- `RTMIFY_NOTARY_KEYCHAIN_PROFILE` recommended
- `RTMIFY_NOTARY_KEYCHAIN` optional if you store the profile in a non-default keychain

Fallback environment variables if you do not use a keychain profile:

- `RTMIFY_NOTARY_KEY_FILE`
- `RTMIFY_NOTARY_KEY_ID`
- `RTMIFY_NOTARY_ISSUER_UUID`

### Windows signing

- `jsign`
  - or `java` plus `JSIGN_JAR=/abs/path/to/jsign.jar`
- Azure CLI logged into the signing tenant
  - or `AZURE_ACCESS_TOKEN`

Environment variables:

- `AZURE_TRUSTED_SIGNING_ENDPOINT`
- `AZURE_TRUSTED_SIGNING_ACCOUNT`
- `AZURE_TRUSTED_SIGNING_PROFILE`
- `AZURE_ACCESS_TOKEN` optional
- `JSIGN_BIN` or `JSIGN_JAR` optional

`tools/publish.py` defaults to acquiring an Azure Trusted Signing token with:

```bash
az account get-access-token --resource https://codesigning.azure.net
```

Normal local auth:

```bash
az login
gh auth login
```

### Linux packaging

- `tar`
- optional `gpg`

## GitHub Actions

Two workflows matter:

- `.github/workflows/release.yml`
  - raw build check only
  - builds the release directory
  - uploads it as an artifact
  - does not sign or publish anything
- `.github/workflows/windows-installer-packaging.yml`
  - packaging only
  - downloads the signed Windows payload zip from a draft GitHub Release
  - runs Inno Setup on `windows-latest`
  - uploads unsigned installer EXEs as a workflow artifact
  - does not sign anything

No Azure signing secrets should be added to GitHub Actions.

## Operator Flow

All steps are automated by `tools/publish.py`. One command does the full release:

```bash
cd /Users/colinsteele/Projects/rtmify/sys

# Preferred Apple notarization setup: keychain profile + env vars
export APPLE_SIGNING_IDENTITY="Developer ID Application: Iron Brothers Ventures LLC (...)"
export RTMIFY_NOTARY_KEYCHAIN_PROFILE="RTMify-Notary"

# Optional when the profile lives in a non-default keychain
# export RTMIFY_NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

export AZURE_TRUSTED_SIGNING_ENDPOINT="https://eus.codesigning.azure.net/"
export AZURE_TRUSTED_SIGNING_ACCOUNT="RTMify"
export AZURE_TRUSTED_SIGNING_PROFILE="RTMify"

az login

# Full release (all platforms, auto-version):
./tools/publish.py release

# Explicit version:
./tools/publish.py release --version 20260329-a

# Single platform:
./tools/publish.py release --windows

# Preview without executing:
./tools/publish.py release --dry-run

# Check pipeline status:
./tools/publish.py status
```

Equivalent one-shot invocation without relying on environment variables:

```bash
./tools/publish.py release \
  --version 20260329-a \
  --signing-identity "Developer ID Application: Iron Brothers Ventures LLC (...)" \
  --notary-keychain-profile RTMify-Notary \
  --azure-endpoint "https://eus.codesigning.azure.net/" \
  --azure-account RTMify \
  --azure-profile RTMify
```

The `release` subcommand automates these steps in order:

1. Builds the raw release directory via `release.sh`
2. Signs and packages all selected platforms (macOS DMGs, Windows payloads, Linux tarballs)
3. Creates a draft GitHub Release and uploads the Windows payload zip
4. Dispatches the Windows installer packaging workflow and waits for completion
5. Downloads unsigned installers and signs them locally
6. Generates the site download manifest (`latest.json`)
7. Uploads all final assets to the GitHub Release
8. Updates the site repo with the new download manifest

The release stays in **draft** state. Publish it after inspection:

```bash
gh release edit v20260329-a --repo cvillecsteele/rtmify --draft=false
```

### Resuming after failure

If a step fails, fix the issue and re-run with `--skip-build`:

```bash
./tools/publish.py release --version 20260329-a --skip-build
./tools/publish.py release --version 20260329-a --skip-build --windows  # resume Windows only
```

### Packaging without the full pipeline

To run signing/packaging independently (without GitHub release management):

```bash
./tools/publish.py package --release-dir ./dist/20260329-a
./tools/publish.py package --release-dir ./dist/20260329-a --linux
./tools/publish.py package --release-dir ./dist/20260329-a --windows-unsigned-dir ./dist/20260329-a/windows-unsigned
```

## Expected Windows Workflow Assets

The staged payload zip contains exactly:

- `rtmify-trace.exe`
- `RTMify Live.exe`
- `rtmify-live.exe`
- `windows-installer-input.json`

`windows-installer-input.json` declares:

- `version`
- expected unsigned installer filenames
- expected final installer filenames

The Windows workflow validates that contract before compiling installers.

## Publishable Assets

Public release assets should be:

- `packages/macos/*.dmg`
- `packages/windows/*.exe`
- `packages/linux/*.tar.gz`
- `checksums.txt`
- `package-manifest.json`
- `manifest.json`
- `latest.json`
- `validation/*.zip`
- `validation/package/*.pdf`

The Windows payload zip is a staging artifact, not a public download.

## Preflight Checks

Before running a release:

1. Confirm the target version is correct.
2. Confirm the HMAC signing key is present and current.
3. Confirm the `Developer ID Application` identity is available locally.
4. Confirm the `RTMIFY_NOTARY_KEYCHAIN_PROFILE` exists locally, or confirm the raw notary key file, key ID, and issuer are current.
5. Confirm `az login` is against the correct tenant for Azure Trusted Signing.
6. Confirm the Azure endpoint, account, and profile match the approved IBV identity.
7. Confirm `gh auth status` succeeds locally.
8. Confirm the draft GitHub Release tag is `v<version>`.

## Post-Release Verification

After publishing, verify all of the following:

1. A GitHub Release exists in `cvillecsteele/rtmify` for tag `v<version>`.
2. The expected `.dmg`, final Windows installer `.exe`, Linux tarball, metadata, and validation assets are attached.
3. `checksums.txt` is present in the release assets.
4. `latest.json` references the same version and tag.
5. `cvillecsteele/rtmifysite` has a commit updating `public/downloads/latest.json`.
6. The Pages deploy in `cvillecsteele/rtmifysite` succeeds.
7. `https://rtmify.io/download` shows the new version and working installer links.
8. Download at least one macOS, Windows, and Linux asset and confirm the published SHA-256 matches `checksums.txt`.

## Failure Modes

### `release.sh` fails

This is a build or validation failure. No public release should be created.

Typical causes:

- missing HMAC key
- missing Python `openpyxl`
- validation dependency failure
- product build failure

### Packaging fails

This is a local signing or packaging failure before CI packaging.

Typical causes:

- Apple signing identity not available
- Apple notarization failure
- Azure Trusted Signing authentication failure
- `jsign` not installed or misconfigured

### Windows packaging workflow fails

This is a Windows packaging failure only. Local signing has not been compromised.

Typical causes:

- payload zip missing from the draft release
- malformed `windows-installer-input.json`
- Inno Setup compilation failure
- wrong or missing payload files

### Windows finalize fails

This is a local final-signing or handoff failure.

Typical causes:

- missing payload zip from the staged run
- wrong unsigned installer filenames
- missing unsigned installer files
- Azure Trusted Signing authentication failure

### GitHub publication fails

The assets were prepared locally, but GitHub publication failed.

Typical causes:

- tag conflict
- permission issue
- bad asset upload

### Site manifest update fails

The GitHub Release may still be valid, but `rtmify.io/download` will not move to the new version automatically.

Typical causes:

- invalid or expired site repo token
- push protection on `cvillecsteele/rtmifysite`
- site repo unavailable

## Rollback

If the site manifest points to a bad release:

1. Revert `public/downloads/latest.json` in `rtmifysite` to the previous known-good version.
2. Push that revert to `main` so Pages redeploys.
3. Leave the GitHub Release in draft or remove the broken assets.

If the GitHub Release is fine but the site is stale:

1. Regenerate or recover the correct `latest.json`.
2. Commit it to `rtmifysite/public/downloads/latest.json`.
3. Push and verify `rtmify.io/download`.

## Operator Notes

- Do not use Wine or local Inno Setup on macOS for this workflow.
- Do not sign in GitHub Actions.
- Do not upload unsigned installers to the GitHub Release.
- The Windows Live installer depends on both `RTMify Live.exe` and `rtmify-live.exe`; packaging only one of them is a broken release.
- Windows signing is two-phase by design: stage locally, package in CI, finalize locally. `tools/publish.py release` automates the full round-trip.
