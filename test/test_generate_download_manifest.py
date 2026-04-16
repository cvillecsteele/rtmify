import json
import tempfile
import unittest
from pathlib import Path

from tools.generate_download_manifest import build_manifest


class GenerateDownloadManifestTests(unittest.TestCase):
    def test_build_manifest_includes_packaged_assets_and_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            release_dir = Path(tmp_dir)
            (release_dir / "packages" / "macos").mkdir(parents=True)
            (release_dir / "packages" / "windows").mkdir(parents=True)
            (release_dir / "packages" / "linux").mkdir(parents=True)
            (release_dir / "validation" / "package").mkdir(parents=True)

            (release_dir / "packages" / "macos" / "RTMify_Trace_20260329-a.dmg").write_bytes(b"mac trace")
            (release_dir / "packages" / "linux" / "rtmify-trace-linux-x64-20260329-a.tar.gz").write_bytes(b"linux trace")
            (release_dir / "packages" / "windows" / "RTMify_Trace_Installer_20260329-a.exe").write_bytes(b"win trace signed")
            (release_dir / "checksums.txt").write_text("abc  checksums.txt\n", encoding="utf-8")
            (release_dir / "validation" / "RTMify_Trace_Validation_Package_v20260329-a.zip").write_bytes(b"zip")
            (release_dir / "validation" / "package" / "RTMify_Trace_IQOQ_Protocol_v20260329-a.pdf").write_bytes(b"pdf")

            (release_dir / "package-manifest.json").write_text(
                json.dumps(
                    {
                        "version": "20260329-a",
                        "macos": {
                            "disk_images": [
                                {
                                    "product": "trace",
                                    "path": "packages/macos/RTMify_Trace_20260329-a.dmg",
                                    "sha256": "mac-sha",
                                }
                            ]
                        },
                        "linux": {
                            "packages": [
                                {
                                    "product": "trace",
                                    "path": "packages/linux/rtmify-trace-linux-x64-20260329-a.tar.gz",
                                    "sha256": "linux-sha",
                                }
                            ]
                        },
                        "windows": {
                            "status": "finalized",
                            "payload_zip": {
                                "path": "packages/windows/RTMify_Windows_Payloads_20260329-a.zip",
                                "sha256": "payload-sha",
                            },
                            "installers": [
                                {
                                    "product": "trace",
                                    "path": "packages/windows/RTMify_Trace_Installer_20260329-a.exe",
                                    "sha256": "win-sha",
                                }
                            ]
                        },
                    }
                ),
                encoding="utf-8",
            )
            (release_dir / "manifest.json").write_text(
                json.dumps(
                    {
                        "version": "20260329-a",
                        "artifacts": [
                            {
                                "product": "trace-validation",
                                "platform": "any",
                                "kind": "zip",
                                "path": "validation/RTMify_Trace_Validation_Package_v20260329-a.zip",
                                "sha256": "zip-sha",
                            },
                            {
                                "product": "trace-validation",
                                "platform": "any",
                                "kind": "pdf",
                                "path": "validation/package/RTMify_Trace_IQOQ_Protocol_v20260329-a.pdf",
                                "sha256": "pdf-sha",
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )

            manifest = build_manifest(release_dir, "cvillecsteele/rtmify", "v20260329-a")

            self.assertEqual("20260329-a", manifest["version"])
            self.assertEqual("v20260329-a", manifest["tag"])
            self.assertEqual(
                "https://github.com/cvillecsteele/rtmify/releases/tag/v20260329-a",
                manifest["releaseUrl"],
            )

            assets = manifest["assets"]
            self.assertTrue(any(asset["filename"] == "RTMify_Trace_20260329-a.dmg" for asset in assets))
            self.assertTrue(any(asset["filename"] == "RTMify_Trace_Installer_20260329-a.exe" for asset in assets))
            self.assertTrue(any(asset["filename"] == "checksums.txt" for asset in assets))
            self.assertTrue(any(asset["filename"] == "RTMify_Trace_Validation_Package_v20260329-a.zip" for asset in assets))
            self.assertTrue(any(asset["filename"] == "RTMify_Trace_IQOQ_Protocol_v20260329-a.pdf" for asset in assets))

            windows_asset = next(asset for asset in assets if asset["filename"] == "RTMify_Trace_Installer_20260329-a.exe")
            self.assertEqual("windows", windows_asset["platform"])
            self.assertEqual("trace", windows_asset["product"])
            self.assertEqual(
                "https://github.com/cvillecsteele/rtmify/releases/download/v20260329-a/RTMify_Trace_Installer_20260329-a.exe",
                windows_asset["url"],
            )
            self.assertEqual("win-sha", windows_asset["sha256"])

    def test_build_manifest_omits_windows_payload_zip_before_finalize(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            release_dir = Path(tmp_dir)
            (release_dir / "packages" / "windows").mkdir(parents=True)
            (release_dir / "checksums.txt").write_text("abc  checksums.txt\n", encoding="utf-8")
            (release_dir / "packages" / "windows" / "RTMify_Windows_Payloads_20260329-a.zip").write_bytes(b"payload")

            (release_dir / "package-manifest.json").write_text(
                json.dumps(
                    {
                        "version": "20260329-a",
                        "windows": {
                            "status": "payloads_signed",
                            "signed_binaries": [
                                "windows/rtmify-trace.exe",
                                "windows/RTMify Live.exe",
                                "windows/rtmify-live.exe",
                            ],
                            "payload_zip": {
                                "path": "packages/windows/RTMify_Windows_Payloads_20260329-a.zip",
                                "sha256": "payload-sha",
                            },
                            "installers": [],
                        },
                    }
                ),
                encoding="utf-8",
            )
            (release_dir / "manifest.json").write_text(
                json.dumps({"version": "20260329-a", "artifacts": []}),
                encoding="utf-8",
            )

            manifest = build_manifest(release_dir, "cvillecsteele/rtmify", "v20260329-a")
            asset_names = {asset["filename"] for asset in manifest["assets"]}
            self.assertNotIn("RTMify_Windows_Payloads_20260329-a.zip", asset_names)


if __name__ == "__main__":
    unittest.main()
