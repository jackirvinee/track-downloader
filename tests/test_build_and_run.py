import os
import subprocess
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(os.uname().sysname == "Darwin", "Track Downloader build script is macOS-only")
class BuildAndRunArgumentTests(unittest.TestCase):
    """Argument rejection must happen before the release build has side effects."""

    def safe_environment(self, root: Path) -> dict[str, str]:
        environment = os.environ.copy()
        environment.pop("TRACK_DOWNLOADER_INSTALL_TEST_HOOK", None)
        environment.pop("TRACK_DOWNLOADER_INSTALL_TESTING", None)
        environment["TRACK_DOWNLOADER_INSTALL_ROOT"] = str(root / "Applications")
        environment["TRACK_DOWNLOADER_BUILD_ROOT"] = str(root / "Build")
        return environment

    def run_build(
        self, *arguments: str, overrides: dict[str, str] | None = None
    ) -> tuple[subprocess.CompletedProcess[str], Path]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        environment = self.safe_environment(root)
        if overrides:
            environment.update(overrides)
        return (
            subprocess.run(
                ["bash", "script/build_and_run.sh", *arguments],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            ),
            root / "Applications",
        )

    def test_invalid_mode_is_rejected_before_creating_override_install_root(self) -> None:
        """A typo must not build, install, or even create TRACK_DOWNLOADER_INSTALL_ROOT."""
        result, install_root = self.run_build("not-a-mode")

        self.assertEqual(result.returncode, 2)
        self.assertFalse(install_root.exists())

    def test_extra_argument_is_rejected_before_creating_override_install_root(self) -> None:
        """A valid mode plus junk must be rejected before any release side effect."""
        result, install_root = self.run_build("--bundle-check", "unexpected")

        self.assertEqual(result.returncode, 2)
        self.assertFalse(install_root.exists())

    def test_release_bundle_check_installs_signed_copy_in_override_root(self) -> None:
        """A controlled release check must update the supplied Applications copy."""
        result, install_root = self.run_build("--bundle-check")
        installed = install_root / "Track Downloader.app"

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(installed.exists())
        self.assertIn(f"Installed {installed.resolve()}", result.stdout)
        subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(installed)], check=True
        )
        staged = install_root.parent / "Build" / "Track Downloader.app"
        self.assertEqual(
            (staged / "Contents" / "MacOS" / "TrackDownloader").read_bytes(),
            (installed / "Contents" / "MacOS" / "TrackDownloader").read_bytes(),
        )

    def test_debug_configuration_does_not_create_override_install_root(self) -> None:
        """Debug bundle checks remain local and never invoke the release installer."""
        result, install_root = self.run_build(
            "--bundle-check", overrides={"TRACK_DOWNLOADER_BUILD_CONFIGURATION": "debug"}
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(install_root.exists())

    def test_release_bundle_check_uses_external_build_root(self) -> None:
        """A FileProvider-managed checkout must not host mutable SwiftPM build state."""
        with tempfile.TemporaryDirectory() as temporary:
            build_root = Path(temporary) / "swift-build"
            result, install_root = self.run_build(
                "--bundle-check",
                overrides={"TRACK_DOWNLOADER_BUILD_ROOT": str(build_root)},
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((install_root / "Track Downloader.app").exists())
            self.assertTrue(build_root.exists())

    def test_repo_root_cannot_be_used_as_the_build_root(self) -> None:
        """A caller-controlled build root cannot target the checked-out app bundle."""
        result, install_root = self.run_build(
            "--bundle-check",
            overrides={"TRACK_DOWNLOADER_BUILD_ROOT": str(Path.cwd())},
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("unsafe build root", result.stderr)
        self.assertFalse(install_root.exists())
        self.assertTrue((Path("Track Downloader.app") / "Contents" / "Info.plist").exists())

    def test_symlinked_build_root_cannot_escape_temporary_directory(self) -> None:
        """Canonical-path validation runs before the staged bundle is removed."""
        with tempfile.TemporaryDirectory() as temporary:
            escaped_build_root = Path(temporary) / "escaped-build"
            escaped_build_root.symlink_to(Path.cwd(), target_is_directory=True)
            result, install_root = self.run_build(
                "--bundle-check",
                overrides={"TRACK_DOWNLOADER_BUILD_ROOT": str(escaped_build_root)},
            )

            self.assertEqual(result.returncode, 2)
            self.assertIn("unsafe build root", result.stderr)
            self.assertFalse(install_root.exists())
            self.assertTrue((Path("Track Downloader.app") / "Contents" / "Info.plist").exists())

if __name__ == "__main__":
    unittest.main()
