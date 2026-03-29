# Release Operations

This document is the operator runbook for producing RTMify release artifacts, publishing them to GitHub Releases, and updating the installer links served by `rtmify.io`.

## Scope

This workflow spans two repositories:

- `cvillecsteele/rtmify`
  Contains the product code, `release.sh`, `package.sh`, the GitHub Release assets, and the release automation workflow.
- `cvillecsteele/rtmifysite`
  Hosts `rtmify.io` on GitHub Pages and publishes the checked-in download manifest at `public/downloads/latest.json`.

## Concepts

- `release.sh`
  Builds a versioned release directory containing the raw release artifacts and `manifest.json`.
- `package.sh`
  Validates the release directory, signs and packages platform artifacts, updates `checksums.txt`, and writes `package-manifest.json`.
- GitHub Release
  Hosts the public downloadable installer assets.
- `latest.json`
  The site-facing manifest containing the current release version and direct GitHub Release asset URLs.

## Normal Release Path

The preferred operator path is the GitHub Actions workflow in `.github/workflows/release.yml`.

That workflow:

1. Checks out `cvillecsteele/rtmify`
2. Installs Zig, Python, Node, .NET, and validation dependencies
3. Runs `./release.sh --version <version>`
4. Runs `./package.sh --release-dir <release-dir>`
5. Generates `latest.json`
6. Creates or updates the GitHub Release `v<version>`
7. Uploads public assets to the GitHub Release
8. Checks out `cvillecsteele/rtmifysite`
9. Updates `public/downloads/latest.json`
10. Pushes that change to `main`, which triggers the Pages deploy

Pushes do not run this workflow. It is manual-only via `workflow_dispatch`.

## Required GitHub Setup

### `cvillecsteele/rtmify` repository secrets

The release workflow requires these secrets:

- `RTMIFY_LICENSE_HMAC_KEY`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_INSTALLER_IDENTITY`
- `RTMIFY_NOTARY_KEY_P8`
- `RTMIFY_NOTARY_KEY_ID`
- `RTMIFY_NOTARY_ISSUER_UUID`
- `AZURE_TENANT_ID`
- `AZURE_CLIENT_ID`
- `AZURE_CLIENT_SECRET`
- `AZURE_TRUSTED_SIGNING_ENDPOINT`
- `AZURE_TRUSTED_SIGNING_ACCOUNT`
- `AZURE_TRUSTED_SIGNING_PROFILE`
- `RTMIFY_SITE_REPO_TOKEN`

### `RTMIFY_SITE_REPO_TOKEN`

This token must be able to push to `cvillecsteele/rtmifysite`.

Minimum useful access:

- repository: `cvillecsteele/rtmifysite`
- permission: `Contents: Read and write`

### GitHub Actions permissions

The `cvillecsteele/rtmify` repo must allow Actions to:

- create releases
- upload release assets
- use workflow `contents: write`

## Running a Release

Use the Actions tab in `cvillecsteele/rtmify`.

Run the workflow:

- workflow: `Release Packages`
- input `version`: `YYYYMMDD-suffix`, for example `20260329-a`
- input `publish_site_manifest`: normally `true`
- input `draft`: `true` if you want to inspect the GitHub Release before publishing it

Expected Git tag and release name:

- tag: `v<version>`
- release name: `RTMify <version>`

## Public Assets

The release workflow uploads these assets when present:

- `packages/macos/*.pkg`
- `packages/linux/*.tar.gz`
- `windows/*.exe`
- `checksums.txt`
- `package-manifest.json`
- `manifest.json`
- `latest.json`
- `validation/*.zip`
- `validation/package/*.pdf`

The website does not serve installers directly from GitHub Pages. Instead, `rtmify.io/download` renders links from `public/downloads/latest.json`, and those links point to GitHub Release assets.

## Local Operator Flow

Local execution is still useful for debugging and packaging verification.

### Build a release directory

```bash
./release.sh --version 20260329-a --out-dir ./dist/20260329-a
```

### Package that release directory

```bash
./package.sh --release-dir ./dist/20260329-a
```

### Generate the site download manifest locally

```bash
python3 ./tools/generate_download_manifest.py \
  --release-dir ./dist/20260329-a \
  --repo cvillecsteele/rtmify \
  --tag v20260329-a \
  --output ./dist/20260329-a/latest.json
```

Local execution does not create a GitHub Release and does not update `rtmifysite` unless you push those changes yourself.

## Preflight Checks

Before running a release:

1. Confirm the target version is correct.
2. Confirm the required GitHub secrets are present and current.
3. Confirm Apple signing identities are valid.
4. Confirm Azure Trusted Signing credentials are valid.
5. Confirm `cvillecsteele/rtmifysite` accepts pushes from the token used by `RTMIFY_SITE_REPO_TOKEN`.

## Post-Release Verification

After a successful workflow run, verify all of the following:

1. A GitHub Release exists in `cvillecsteele/rtmify` for tag `v<version>`.
2. The expected release assets are attached.
3. `checksums.txt` is present in the release assets.
4. `latest.json` in the release assets references the same version and tag.
5. `cvillecsteele/rtmifysite` has a commit updating `public/downloads/latest.json`.
6. The Pages deploy in `cvillecsteele/rtmifysite` succeeds.
7. `https://rtmify.io/download` shows the new version and working installer links.
8. Download at least one macOS, Windows, and Linux asset and confirm the published SHA-256 matches `checksums.txt`.

## Failure Modes

### `release.sh` fails

This is a build or validation failure. No GitHub Release should be created.

Typical causes:

- missing HMAC key
- missing Python `openpyxl`
- validation dependency failure
- product build failure

### `package.sh` fails

This is a packaging or signing failure. The release directory may exist, but public release publication should not proceed.

Typical causes:

- release directory missing required artifacts
- Apple signing identity not available
- Apple notarization failure
- Azure Trusted Signing failure

### GitHub Release step fails

The artifacts were built, but GitHub publication failed.

Typical causes:

- tag conflict
- permission issue
- Actions token/release permission problem

### Site manifest update fails

The GitHub Release may still be valid, but `rtmify.io/download` will not move to the new version automatically.

Typical causes:

- invalid or expired `RTMIFY_SITE_REPO_TOKEN`
- push protection on `cvillecsteele/rtmifysite`
- site repo unavailable

If this happens:

1. Confirm the GitHub Release itself is correct.
2. Copy the generated `latest.json` from the release output or release assets.
3. Update `cvillecsteele/rtmifysite/public/downloads/latest.json` manually.
4. Push to `main` in `rtmifysite`.

## Rollback

If the site manifest points to a bad release:

1. Revert `public/downloads/latest.json` in `cvillecsteele/rtmifysite` to the previous known-good version.
2. Push that revert to `main` so Pages redeploys.
3. If needed, edit the GitHub Release in `cvillecsteele/rtmify` to draft or remove the broken assets.

If the GitHub Release is fine but the site is stale:

1. Regenerate or recover the correct `latest.json`.
2. Commit it to `cvillecsteele/rtmifysite/public/downloads/latest.json`.
3. Push and verify `rtmify.io/download`.

## Operator Notes

- `package.sh` now validates that the release directory actually matches `release.sh` output before packaging begins.
- `checksums.txt` is updated during packaging so the published checksums reflect post-signing artifacts, including Windows `.exe` files.
- The website consumes a checked-in JSON manifest at build time. This is intentional because `rtmify.io` is hosted on GitHub Pages and cannot rely on runtime server logic.
