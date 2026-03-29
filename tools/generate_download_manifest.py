#!/usr/bin/env python3

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def infer_product(rel_path: str) -> str:
    lower = rel_path.lower()
    if "trace" in lower:
        return "trace"
    if "live" in lower:
        return "live"
    if "license" in lower:
        return "operator"
    return "unknown"


def infer_kind(rel_path: str) -> str:
    name = Path(rel_path).name.lower()
    if name.endswith(".pkg"):
        return "pkg"
    if name.endswith(".exe"):
        return "exe"
    if name.endswith(".tar.gz"):
        return "tar.gz"
    if name.endswith(".zip"):
        return "zip"
    if name.endswith(".pdf"):
        return "pdf"
    if name.endswith(".json"):
        return "json"
    if name.endswith(".txt"):
        return "txt"
    return Path(rel_path).suffix.lstrip(".") or "file"


def release_url(repo: str, tag: str, asset_name: str | None = None) -> str:
    base = f"https://github.com/{repo}/releases"
    if asset_name is None:
        return f"{base}/tag/{tag}"
    return f"{base}/download/{tag}/{asset_name}"


def build_asset_entry(
    *,
    repo: str,
    tag: str,
    version: str,
    release_dir: Path,
    rel_path: str,
    product: str,
    platform: str,
    kind: str | None = None,
    sha256: str | None = None,
) -> dict[str, Any]:
    filename = Path(rel_path).name
    abs_path = release_dir / rel_path
    return {
        "product": product,
        "platform": platform,
        "version": version,
        "path": rel_path,
        "filename": filename,
        "kind": kind or infer_kind(rel_path),
        "sha256": sha256 or sha256_path(abs_path),
        "url": release_url(repo, tag, filename),
    }


def build_manifest(release_dir: Path, repo: str, tag: str) -> dict[str, Any]:
    release_manifest = load_json(release_dir / "manifest.json")
    package_manifest = load_json(release_dir / "package-manifest.json")
    version = release_manifest["version"]

    assets: list[dict[str, Any]] = []

    for pkg in package_manifest.get("macos", {}).get("packages", []):
        assets.append(
            build_asset_entry(
                repo=repo,
                tag=tag,
                version=version,
                release_dir=release_dir,
                rel_path=pkg["path"],
                product=pkg["product"],
                platform="macos",
                sha256=pkg.get("sha256"),
            )
        )

    for pkg in package_manifest.get("linux", {}).get("packages", []):
        assets.append(
            build_asset_entry(
                repo=repo,
                tag=tag,
                version=version,
                release_dir=release_dir,
                rel_path=pkg["path"],
                product=pkg["product"],
                platform="linux",
                sha256=pkg.get("sha256"),
            )
        )

    for rel_path in package_manifest.get("windows", {}).get("signed", []):
        assets.append(
            build_asset_entry(
                repo=repo,
                tag=tag,
                version=version,
                release_dir=release_dir,
                rel_path=rel_path,
                product=infer_product(rel_path),
                platform="windows",
            )
        )

    utility_paths = [
        ("checksums.txt", "metadata", "any"),
        ("package-manifest.json", "metadata", "any"),
        ("manifest.json", "metadata", "any"),
    ]
    for rel_path, product, platform in utility_paths:
        if (release_dir / rel_path).exists():
            assets.append(
                build_asset_entry(
                    repo=repo,
                    tag=tag,
                    version=version,
                    release_dir=release_dir,
                    rel_path=rel_path,
                    product=product,
                    platform=platform,
                )
            )

    for artifact in release_manifest.get("artifacts", []):
        rel_path = artifact.get("path")
        if not rel_path or not isinstance(rel_path, str):
            continue
        if not rel_path.startswith("validation/"):
            continue
        abs_path = release_dir / rel_path
        if not abs_path.exists() or abs_path.is_dir():
            continue
        assets.append(
            build_asset_entry(
                repo=repo,
                tag=tag,
                version=version,
                release_dir=release_dir,
                rel_path=rel_path,
                product=artifact.get("product", "validation"),
                platform=artifact.get("platform", "any"),
                kind=artifact.get("kind"),
                sha256=artifact.get("sha256"),
            )
        )

    assets.sort(key=lambda item: (item["platform"], item["product"], item["filename"]))

    return {
        "version": version,
        "tag": tag,
        "releaseUrl": release_url(repo, tag),
        "repo": repo,
        "assets": assets,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate site download manifest from a packaged release dir.")
    parser.add_argument("--release-dir", required=True, help="Path to a packaged release directory")
    parser.add_argument("--repo", required=True, help="GitHub repo in owner/name form")
    parser.add_argument("--tag", required=True, help="Git tag for the GitHub release")
    parser.add_argument("--output", required=True, help="Where to write the generated manifest JSON")
    args = parser.parse_args()

    manifest = build_manifest(Path(args.release_dir), args.repo, args.tag)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
