import os
import tempfile
import unittest
from unittest import mock
from pathlib import Path

from script import verify_public_release_tree
from script.verify_public_release_tree import audit_public_tree


class PublicReleaseTreeTests(unittest.TestCase):
    def finding_kinds(self, root: Path) -> set[str]:
        return {finding.kind for finding in audit_public_tree(root)}

    def test_accepts_a_minimal_source_only_tree(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "README.md").write_text("# Track Downloader\n", encoding="utf-8")
            source = root / "Sources" / "TrackDownloader"
            source.mkdir(parents=True)
            (source / "Main.swift").write_text("print(\"Track Downloader\")\n", encoding="utf-8")
            bundle = root / "Track Downloader.app" / "Contents"
            bundle.mkdir(parents=True)
            (bundle / "Info.plist").write_text("<plist/>\n", encoding="utf-8")

            self.assertEqual(audit_public_tree(root), [])

    def test_rejects_internal_planning_and_vcs_metadata(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            for path in (root / ".git" / "config", root / "docs" / "superpowers" / "plan.md"):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("internal\n", encoding="utf-8")

            self.assertIn("internal-path", self.finding_kinds(root))

    def test_rejects_high_confidence_secrets_and_personal_absolute_paths(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "notes.txt").write_text(
                "token=" + "ghp" + "_abcdefghijklmnopqrstuvwxyz1234567890\n"
                "build=" + "/" + "Users" + "/" + "example" + "/Private" + "/project\n",
                encoding="utf-8",
            )

            kinds = self.finding_kinds(root)
            self.assertIn("possible-secret", kinds)
            self.assertIn("personal-path", kinds)

    def test_rejects_secret_after_one_mebibyte_in_permitted_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            secret_prefix = b" gh" + b"p_"
            (root / "large-source.txt").write_bytes(
                b"x" * (1024 * 1024 - len(secret_prefix))
                + secret_prefix
                + b"abcdefghijklmnopqrstuvwxyz1234567890\n"
            )

            self.assertIn("possible-secret", self.finding_kinds(root))

    def test_accepts_large_binary_file_without_prohibited_content(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "large-data.bin").write_bytes(b"\x00" * (1024 * 1024 + 1))

            self.assertEqual(audit_public_tree(root), [])

    def test_rejects_windows_personal_path_split_across_scan_chunks(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "binary-data.bin").write_bytes(
                b"\xff" * (64 * 1024 - len(b"C:\\Users\\"))
                + b"C:\\Users\\private\\release-notes.txt\x00"
            )

            self.assertIn("personal-path", self.finding_kinds(root))

    def test_accepts_file_at_public_size_limit_without_prohibited_content(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "maximum-size.bin").write_bytes(b"\x00" * (10 * 1024 * 1024))

            self.assertEqual(audit_public_tree(root), [])

    def test_rejects_oversized_file_without_scanning_its_content(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "oversized-source.txt").write_bytes(
                b"\x00" * (10 * 1024 * 1024)
                + b" gh" + b"p_abcdefghijklmnopqrstuvwxyz1234567890\n"
            )

            self.assertEqual(self.finding_kinds(root), {"large-file"})

    def test_rejects_generated_bundle_code_signatures_logs_and_media(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            generated = (
                root / "Track Downloader.app" / "Contents" / "MacOS" / "TrackDownloader",
                root / "Track Downloader.app" / "Contents" / "_CodeSignature" / "CodeResources",
                root / "track-downloader-last-download.log",
                root / "download.opus",
            )
            for path in generated:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"generated")

            kinds = self.finding_kinds(root)
            self.assertIn("generated-artifact", kinds)
            self.assertIn("private-runtime-data", kinds)

    def test_rejects_symlinks(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            outside = root.parent / "outside-public-tree-test.txt"
            outside.write_text("outside\n", encoding="utf-8")
            try:
                (root / "linked.txt").symlink_to(outside)
                self.assertIn("symlink", self.finding_kinds(root))
            finally:
                outside.unlink(missing_ok=True)

    def test_rejects_file_swapped_to_a_symlink_after_the_type_check(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            candidate = root / "race.txt"
            candidate.write_text("safe\n", encoding="utf-8")
            outside = root.parent / "outside-file-race.txt"
            outside.write_text(
                "build=" + "/" + "Users" + "/" + "private" + "/release\n", encoding="utf-8"
            )
            original_stat = os.stat
            swapped = False

            def swap_after_stat(path, *args, **kwargs):
                nonlocal swapped
                result = original_stat(path, *args, **kwargs)
                if not swapped and (path == "race.txt" or Path(path) == candidate):
                    swapped = True
                    candidate.unlink()
                    candidate.symlink_to(outside)
                return result

            try:
                with mock.patch("script.verify_public_release_tree.os.stat", side_effect=swap_after_stat):
                    kinds = self.finding_kinds(root)
            finally:
                outside.unlink(missing_ok=True)

            self.assertNotIn("personal-path", kinds)
            self.assertTrue({"symlink", "unreadable"} & kinds)

    def test_rejects_regular_file_replaced_after_its_opened_content_is_scanned(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            candidate = root / "race.txt"
            candidate.write_text("safe\n", encoding="utf-8")
            original_scan_content = verify_public_release_tree._scan_content

            def replace_after_scan(relative: Path, file_descriptor: int):
                findings = original_scan_content(relative, file_descriptor)
                candidate.unlink()
                candidate.write_text("replacement\n", encoding="utf-8")
                return findings

            with mock.patch.object(
                verify_public_release_tree, "_scan_content", side_effect=replace_after_scan
            ):
                kinds = self.finding_kinds(root)

            self.assertIn("changed-during-verification", kinds)

    def test_rejects_regular_file_rewritten_in_place_after_its_content_is_scanned(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            candidate = root / "race.txt"
            candidate.write_text("safe\n", encoding="utf-8")
            original_scan_content = verify_public_release_tree._scan_content

            def rewrite_after_scan(relative: Path, file_descriptor: int):
                findings = original_scan_content(relative, file_descriptor)
                candidate.write_text(
                    "git" + "hub_pat_" + "abcdefghijklmnopqrstuvwxyz1234567890\n",
                    encoding="utf-8",
                )
                return findings

            with mock.patch.object(
                verify_public_release_tree, "_scan_content", side_effect=rewrite_after_scan
            ):
                kinds = self.finding_kinds(root)

            self.assertIn("changed-during-verification", kinds)

    def test_rejects_directory_replaced_after_its_contents_are_scanned(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            nested = root / "nested"
            nested.mkdir()
            safe_file = nested / "safe.txt"
            safe_file.write_text("safe\n", encoding="utf-8")
            replacement = root / "replacement"
            replacement.mkdir()
            (replacement / "private.txt").write_text(
                "git" + "hub_pat_" + "abcdefghijklmnopqrstuvwxyz1234567890\n", encoding="utf-8"
            )
            original_scan_content = verify_public_release_tree._scan_content

            def replace_directory_after_scan(relative: Path, file_descriptor: int):
                findings = original_scan_content(relative, file_descriptor)
                if relative == Path("nested/safe.txt"):
                    nested.rename(root / "previous-nested")
                    replacement.rename(nested)
                return findings

            with mock.patch.object(
                verify_public_release_tree, "_scan_content", side_effect=replace_directory_after_scan
            ):
                kinds = self.finding_kinds(root)

            self.assertIn("changed-during-verification", kinds)

    def test_rejects_directory_swapped_to_a_symlink_after_the_type_check(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            nested = root / "nested"
            nested.mkdir()
            outside = root.parent / "outside-directory-race"
            outside.mkdir(exist_ok=True)
            (outside / "private.txt").write_text(
                "build=" + "/" + "Users" + "/" + "private" + "/release\n", encoding="utf-8"
            )
            original_is_symlink = Path.is_symlink
            original_stat = os.stat
            swapped = False

            def swap_directory() -> None:
                nonlocal swapped
                if not swapped:
                    swapped = True
                    nested.rmdir()
                    nested.symlink_to(outside, target_is_directory=True)

            def swap_after_is_symlink(path):
                result = original_is_symlink(path)
                if not result and path == nested:
                    swap_directory()
                return result

            def swap_after_stat(path, *args, **kwargs):
                result = original_stat(path, *args, **kwargs)
                if path == "nested" or Path(path) == nested:
                    swap_directory()
                return result

            try:
                with mock.patch.object(Path, "is_symlink", new=swap_after_is_symlink), mock.patch(
                    "script.verify_public_release_tree.os.stat", side_effect=swap_after_stat
                ):
                    kinds = self.finding_kinds(root)
            finally:
                if nested.is_symlink():
                    nested.unlink()
                outside.joinpath("private.txt").unlink(missing_ok=True)
                outside.rmdir()

            self.assertNotIn("personal-path", kinds)
            self.assertTrue({"symlink", "unreadable"} & kinds)

    def test_accepts_static_nested_source_tree(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "Sources" / "TrackDownloader"
            source.mkdir(parents=True)
            (source / "Main.swift").write_text("print(\"Track Downloader\")\n", encoding="utf-8")

            self.assertEqual(audit_public_tree(root), [])


if __name__ == "__main__":
    unittest.main()
