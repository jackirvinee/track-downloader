import json
import struct
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_ROOT = ROOT / "windows" / "TrackDownloader.Windows.Package"
MANIFEST = PACKAGE_ROOT / "AppxManifest.xml"


class WindowsPackagingContractTests(unittest.TestCase):
    def test_manifest_declares_a_full_trust_x64_desktop_package(self):
        root = ET.parse(MANIFEST).getroot()
        ns = {
            "f": "http://schemas.microsoft.com/appx/manifest/foundation/windows10",
            "rescap": "http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities",
        }

        identity = root.find("f:Identity", ns)
        self.assertIsNotNone(identity)
        self.assertEqual(identity.attrib["Name"], "com.jackirvine.trackdownloader")
        self.assertEqual(identity.attrib["Version"], "0.1.0.0")
        self.assertEqual(identity.attrib["ProcessorArchitecture"], "x64")

        family = root.find("f:Dependencies/f:TargetDeviceFamily", ns)
        self.assertIsNotNone(family)
        self.assertEqual(family.attrib["Name"], "Windows.Desktop")
        self.assertEqual(family.attrib["MinVersion"], "10.0.17763.0")

        capability = root.find("f:Capabilities/rescap:Capability", ns)
        self.assertIsNotNone(capability)
        self.assertEqual(capability.attrib["Name"], "runFullTrust")

        application = root.find("f:Applications/f:Application", ns)
        self.assertIsNotNone(application)
        self.assertEqual(application.attrib["Executable"], "TrackDownloader.Windows.exe")
        self.assertEqual(application.attrib["EntryPoint"], "Windows.FullTrustApplication")

    def test_manifest_assets_are_real_pngs_with_declared_dimensions(self):
        for name, dimensions in (
            ("Square44x44Logo.png", (44, 44)),
            ("Square150x150Logo.png", (150, 150)),
            ("StoreLogo.png", (50, 50)),
        ):
            payload = (PACKAGE_ROOT / "Assets" / name).read_bytes()
            self.assertEqual(payload[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", payload[16:24]), dimensions)

    def test_build_script_keeps_unsigned_build_and_trusted_signing_as_separate_states(self):
        script = (ROOT / "script" / "build_windows_package.ps1").read_text(encoding="utf-8")

        for required in (
            "dotnet publish",
            "--self-contained",
            "MakeAppx.exe",
            "SignTool.exe",
            "sign /sha1",
            "/fd SHA256",
            "/td SHA256",
            "verify /pa",
            "Unsigned package built",
        ):
            self.assertIn(required, script)
        self.assertNotIn("CertificatePassword", script)
        self.assertNotIn(".pfx", script.lower())

    def test_device_proof_requires_a_signed_package_and_an_authorized_url(self):
        script = (ROOT / "script" / "verify_windows_device.ps1").read_text(encoding="utf-8")

        self.assertIn("[Parameter(Mandatory = $true)]", script)
        self.assertIn("AuthorizedMediaUrl", script)
        self.assertIn("SignTool.exe", script)
        self.assertIn("verify /pa", script)
        self.assertIn("--js-runtimes", script)
        self.assertIn("--remote-components", script)
        self.assertIn("ejs:github", script)
        self.assertIn("Add-AppxPackage", script)

    def test_ci_and_parity_contract_record_source_packaging_without_claiming_device_proof(self):
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("Build unsigned Windows MSIX package", workflow)
        self.assertIn("script\\build_windows_package.ps1", workflow)

        parity = json.loads((ROOT / "platform-parity.json").read_text(encoding="utf-8"))
        capability = next(item for item in parity["capabilities"] if item["id"] == "installer-signing-device-proof")
        self.assertEqual(capability["windows"]["status"], "partial")
        self.assertEqual(capability["windows"]["verification"], "external-required")
        for evidence in (
            "windows/TrackDownloader.Windows.Package/AppxManifest.xml",
            "script/build_windows_package.ps1",
            "script/verify_windows_device.ps1",
            "tests/test_windows_packaging.py",
        ):
            self.assertIn(evidence, capability["windows"]["evidence"])

    def test_packaging_sources_are_in_the_public_release_allowlist(self):
        allowlist = (ROOT / "script" / "public_release_paths.txt").read_text(encoding="utf-8").splitlines()
        for path in (
            "windows/TrackDownloader.Windows.Package/AppxManifest.xml",
            "windows/TrackDownloader.Windows.Package/Assets/Square44x44Logo.png",
            "windows/TrackDownloader.Windows.Package/Assets/Square150x150Logo.png",
            "windows/TrackDownloader.Windows.Package/Assets/StoreLogo.png",
            "script/build_windows_package.ps1",
            "script/verify_windows_device.ps1",
            "tests/test_windows_packaging.py",
        ):
            self.assertIn(path, allowlist)


if __name__ == "__main__":
    unittest.main()
