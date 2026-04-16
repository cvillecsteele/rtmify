# Release Operations

This is the operator runbook for producing RTMify release artifacts, staging Windows payloads, packaging Windows installers in GitHub Actions, and publishing the final signed assets.

## Scope

This workflow spans two repositories:

- `cvillecsteele/rtmify`
  Contains the product code, `release.sh`, `package.sh`, validation assets, and the GitHub Actions workflows.
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

`package.sh` produces:

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

- `gh`
- `git`
- `python3`

### macOS signing and notarization

- `codesign`
- `xcrun notarytool`
- `xcrun stapler`
- a valid `Developer ID Application` certificate in the login keychain
- notary API key `.p8`, key ID, and issuer UUID

Environment variables:

- `APPLE_SIGNING_IDENTITY`
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

`package.sh` defaults to acquiring an Azure Trusted Signing token with:

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

Use the exact sequence below.

### 1. Build the raw release directory locally

```bash
cd /Users/colinsteele/Projects/rtmify/sys
./release.sh --version 20260329-a --out-dir ./dist/20260329-a
```

### 2. Package locally: macOS, Linux, and Windows payload stage

```bash
export APPLE_SIGNING_IDENTITY="Developer ID Application: Iron Brothers Ventures LLC (...)"
export RTMIFY_NOTARY_KEY_FILE="$HOME/.rtmify/secrets/notary-key.p8"
export RTMIFY_NOTARY_KEY_ID="ABCDEFGHIJ"
export RTMIFY_NOTARY_ISSUER_UUID="00000000-0000-0000-0000-000000000000"

export AZURE_TRUSTED_SIGNING_ENDPOINT="https://eus.codesigning.azure.net/"
export AZURE_TRUSTED_SIGNING_ACCOUNT="RTMify"
export AZURE_TRUSTED_SIGNING_PROFILE="RTMify"

az login

./package.sh --release-dir ./dist/20260329-a
```

This does all of the following:

1. validates the release directory
2. signs macOS CLI binaries and app bundles locally
3. creates signed, notarized macOS `.dmg` files
4. signs the Windows payload EXEs locally
5. creates `packages/windows/RTMify_Windows_Payloads_<version>.zip`
6. creates Linux tarballs
7. rewrites `checksums.txt`
8. writes `package-manifest.json` in `payloads_signed` state for Windows

At this point there are no final Windows installers yet.

### 3. Create or confirm the draft GitHub Release

If the draft release does not exist yet:

```bash
gh release create v20260329-a \
  --draft \
  --title "RTMify 20260329-a"
```

If it already exists, leave it in draft state.

### 4. Upload the signed Windows payload zip to the draft release

```bash
gh release upload v20260329-a \
  ./dist/20260329-a/packages/windows/RTMify_Windows_Payloads_20260329-a.zip \
  --clobber
```

Only the payload zip should be uploaded at this point for the Windows handoff. Do not upload unsigned installers to the draft release.

### 5. Trigger the Windows packaging workflow

```bash
gh workflow run windows-installer-packaging.yml -f version=20260329-a
```

This workflow:

1. downloads `RTMify_Windows_Payloads_<version>.zip` from the draft release
2. installs Inno Setup on `windows-latest`
3. compiles unsigned installers
4. uploads them as a workflow artifact named `windows-installers-unsigned-<version>`

### 6. Download the unsigned installers locally

Get the run id:

```bash
gh run list --workflow windows-installer-packaging.yml --limit 5
```

Download the artifact:

```bash
mkdir -p ./dist/20260329-a/windows-unsigned
gh run download <run-id> \
  --name windows-installers-unsigned-20260329-a \
  --dir ./dist/20260329-a/windows-unsigned
```

Expected files:

- `RTMify_Trace_Installer_<version>_unsigned.exe`
- `RTMify_Live_Installer_<version>_unsigned.exe`

### 7. Finalize Windows locally: sign the installer EXEs

```bash
./package.sh \
  --release-dir ./dist/20260329-a \
  --windows-unsigned-dir ./dist/20260329-a/windows-unsigned
```

When `--windows-unsigned-dir` is set, `package.sh` automatically skips macOS and Linux packaging and only performs Windows finalization.

This step:

1. validates the unsigned installer filenames
2. copies them into `packages/windows/`
3. signs both final installer EXEs locally
4. rewrites `checksums.txt`
5. rewrites `package-manifest.json` in `finalized` state for Windows

### 8. Generate the site download manifest locally

```bash
python3 ./tools/generate_download_manifest.py \
  --release-dir ./dist/20260329-a \
  --repo cvillecsteele/rtmify \
  --tag v20260329-a \
  --output ./dist/20260329-a/latest.json
```

Only finalized Windows installers are included in `latest.json`. The Windows payload zip is intentionally excluded.

### 9. Upload final public assets to the GitHub Release

After Windows finalization succeeds, upload the final public assets:

```bash
gh release upload v20260329-a \
  ./dist/20260329-a/packages/macos/*.dmg \
  ./dist/20260329-a/packages/windows/*.exe \
  ./dist/20260329-a/packages/linux/*.tar.gz \
  ./dist/20260329-a/checksums.txt \
  ./dist/20260329-a/package-manifest.json \
  ./dist/20260329-a/manifest.json \
  ./dist/20260329-a/latest.json \
  ./dist/20260329-a/validation/*.zip \
  ./dist/20260329-a/validation/package/*.pdf \
  --clobber
```

The draft release can remain draft until you finish inspection. Publish it once you are satisfied.

### 10. Update the website download manifest

Copy the generated `latest.json` into the site repo:

```bash
cp ./dist/20260329-a/latest.json /path/to/rtmifysite/public/downloads/latest.json
```

Then commit and push that change to `main` in `rtmifysite`.

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
4. Confirm the notary API key, key ID, and issuer are current.
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

### First `package.sh` run fails

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

### Finalize `package.sh --windows-unsigned-dir ...` fails

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
- `package.sh` is now two-phase for Windows by design: stage locally, package in CI, finalize locally.
