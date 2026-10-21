import plistlib
import unittest
from pathlib import Path


class TrackDownloaderIdentityContractTests(unittest.TestCase):
    def test_dense_workspace_claims_the_window_height(self) -> None:
        content = Path("Sources/TrackDownloader/Views/ContentView.swift").read_text()
        source = Path("Sources/TrackDownloader/Views/SourcePaneView.swift").read_text()

        # HSplitView reports a height derived from each pane's ideal size and
        # ignores the height it is proposed, so flexible frames cannot make the
        # panes fill the window. ContentView must measure the available height
        # and hand each pane a definite one.
        self.assertIn("GeometryReader { proxy in", content)
        self.assertEqual(content.count(".frame(height: proxy.size.height)"), 2)

        # The status bar stays out of the vertical flow so it is bottom-anchored
        # by construction and the panes inherit the remaining height.
        self.assertIn(".safeAreaInset(edge: .bottom, spacing: 0)", content)

        # A pane given a definite height must be able to fill it rather than
        # sit centred inside it.
        self.assertIn("Spacer(minLength: 0)", source)

        # Superseded workarounds that never moved the panes: a top-pinning
        # alignment on the root frame, and greedy frames in the app entry point.
        self.assertNotIn("alignment: .topLeading", content)
        self.assertNotIn(
            ".frame(maxWidth: .infinity, maxHeight: .infinity)",
            Path("Sources/TrackDownloader/App/TrackDownloaderApp.swift").read_text(),
        )

    def test_workspace_has_two_panes_and_an_inline_library_detail_strip(self) -> None:
        app = Path("Sources/TrackDownloader/App/TrackDownloaderApp.swift").read_text()
        content = Path("Sources/TrackDownloader/Views/ContentView.swift").read_text()
        source = Path("Sources/TrackDownloader/Views/SourcePaneView.swift").read_text()
        library = Path("Sources/TrackDownloader/Views/DownloadedTracksView.swift").read_text()
        detail = Path("Sources/TrackDownloader/Views/LibrarySelectionDetailView.swift").read_text()
        status = Path("Sources/TrackDownloader/Views/WorkspaceStatusBar.swift").read_text()

        code = "\n".join(
            line for line in content.splitlines() if not line.lstrip().startswith("//")
        )
        self.assertEqual(code.count("HSplitView"), 1)
        self.assertIn("SourcePaneView", content)
        self.assertIn("DownloadedTracksView(store: downloadedTrackStore, selection: $selectedTrackURL)", content)
        self.assertNotIn("InspectorPaneView", content)
        self.assertIn("LibrarySelectionDetailView", library)
        self.assertIn("Show in Finder", detail)
        self.assertIn("Find Better Source", detail)
        self.assertFalse(Path("Sources/TrackDownloader/Views/InspectorPaneView.swift").exists())
        self.assertIn("WorkspaceStatusBar", content)
        self.assertLess(code.index("HSplitView"), code.index("WorkspaceStatusBar"))
        self.assertIn("history: sourceHistory", content)
        self.assertNotIn("Spacer()", source)
        self.assertIn("presentation.accessibilityLabel", status)
        self.assertIn(".defaultSize(width: 1280, height: 760)", app)

    def test_settings_navigation_and_fixture_appearance_are_separate(self) -> None:
        app = Path("Sources/TrackDownloader/App/TrackDownloaderApp.swift").read_text()
        content = Path("Sources/TrackDownloader/Views/ContentView.swift").read_text()
        source = Path("Sources/TrackDownloader/Views/SourcePaneView.swift").read_text()
        settings = Path("Sources/TrackDownloader/Views/SettingsAboutView.swift").read_text()
        fixture = Path("Sources/TrackDownloader/App/TrackDownloaderFixture.swift").read_text()

        self.assertIn("presentSettings()", content)
        self.assertIn('keyboardShortcut(",", modifiers: .command)', source)
        self.assertIn("Settings {", app)
        self.assertEqual(app.count("appearanceRawValue: $appearanceRawValue"), 3)
        self.assertIn("@Binding var appearanceRawValue: String", settings)
        self.assertNotIn("@AppStorage(AppearancePreference.storageKey)", settings)
        self.assertEqual(app.count(".preferredColorScheme(effectiveColorScheme)"), 3)
        self.assertIn('"TrackDownloaderAppearancePreference"', Path("Sources/TrackDownloader/Models/AppearancePreference.swift").read_text())
        self.assertIn('appearanceValue("TrackDownloaderAppearance")', fixture)
        self.assertNotIn("AppearancePreference.storageKey", fixture)

    def test_settings_uses_explicit_sheet_presentation_and_source_reentry(self) -> None:
        app = Path("Sources/TrackDownloader/App/TrackDownloaderApp.swift").read_text()
        content = Path("Sources/TrackDownloader/Views/ContentView.swift").read_text()
        policy = Path("Sources/TrackDownloader/Models/SourcePanePresentation.swift").read_text()

        self.assertIn("isSettingsSheetPresented", app)
        self.assertIn(".sheet(isPresented: $isSettingsSheetPresented)", app)
        self.assertIn('Button("Settings…")', app)
        self.assertIn("presentSettings: @escaping () -> Void", content)
        self.assertIn("SourceResultReentryPolicy.delayNanoseconds", content)
        self.assertIn("SourceResultReentryPolicy", policy)

    def test_initial_finished_content_state_uses_reentry_lifecycle(self) -> None:
        content = Path("Sources/TrackDownloader/Views/ContentView.swift").read_text()

        self.assertIn("handleFinishedState(result)", content)
        self.assertIn("if case .finished(let result) = store.state", content)
        self.assertNotIn("presentSettings: @escaping () -> Void = {}", content)

    def test_library_is_a_dense_selection_surface_without_a_nested_inspector(self) -> None:
        library = Path("Sources/TrackDownloader/Views/DownloadedTracksView.swift").read_text()
        table = Path("Sources/TrackDownloader/Views/DownloadedTracksTable.swift").read_text()

        self.assertIn("@Binding var selection: URL?", library)
        self.assertIn("DownloadedTracksTable", library)
        self.assertIn("selection: $selection", library)
        self.assertIn("LibraryContentPresentation.resolve", library)
        self.assertNotIn("selectedTrackInspector", library)
        self.assertNotIn('Text("Track details")', library)
        self.assertIn("NSTableView", table)
        self.assertIn("usesAlternatingRowBackgroundColors = true", table)
        self.assertIn("hasHorizontalScroller = true", table)

    def test_native_table_hosts_truthful_artwork_and_waveform_cells(self) -> None:
        table = Path("Sources/TrackDownloader/Views/DownloadedTracksTable.swift").read_text()
        organization = Path("Sources/TrackDownloader/Models/LibraryOrganization.swift").read_text()

        self.assertIn("case .artwork:", table)
        self.assertIn("CatalogueArtworkThumbnail", table)
        self.assertIn("case .waveform:", table)
        self.assertIn("CatalogueWaveformThumbnail", table)
        self.assertIn("AudioWaveformLoading", table)
        self.assertIn("rowHeight = 40", table)
        self.assertIn('case .waveform: "Waveform"', organization)

    def test_vu_meter_icon_assets_are_complete_and_use_signal_colours(self) -> None:
        from PIL import Image

        resources = Path("Track Downloader.app/Contents/Resources")
        with Image.open(resources / "AppIcon-1024.png") as icon:
            self.assertEqual(icon.mode, "RGBA")
            self.assertEqual(icon.size, (1024, 1024))
            self.assertEqual(icon.getpixel((0, 0)), (0, 0, 0, 0))
            # The mark is intentionally a set of bars plus a standalone
            # down-arrow, both on a fully transparent background.
            self.assertEqual(icon.getpixel((512, 700)), (0, 0, 0, 0))
            palette = {pixel[:3] for pixel in icon.getdata()}

        expected_colours = {"#4DCB78", "#E7A43B", "#E05C58", "#E8E7E1"}
        actual_colours = {"#%02X%02X%02X" % rgb for rgb in palette}
        self.assertTrue(expected_colours.issubset(actual_colours))
        self.assertTrue((resources / "AppIcon.icns").is_file())
        for filename, expected_size in {
            "icon_16x16@2x.png": (32, 32),
            "icon_32x32@2x.png": (64, 64),
            "icon_128x128.png": (128, 128),
            "icon_128x128@2x.png": (256, 256),
            "icon_256x256.png": (256, 256),
            "icon_256x256@2x.png": (512, 512),
            "icon_512x512.png": (512, 512),
            "icon_512x512@2x.png": (1024, 1024),
        }.items():
            with Image.open(resources / "AppIcon.iconset" / filename) as representation:
                self.assertEqual(representation.size, expected_size)

    def test_macos_ci_installs_the_icon_test_dependency(self) -> None:
        workflow = Path(".github/workflows/ci.yml").read_text()

        self.assertIn("python3 -m pip install --disable-pip-version-check Pillow==10.4.0", workflow)

    """The staged native bundle must expose the Track Downloader identity."""

    def test_production_shell_remains_compact_and_checks_sources_before_download(self) -> None:
        """Catch a library workspace replacing the compact downloader shell."""
        app = Path("Sources/TrackDownloader/App/TrackDownloaderApp.swift").read_text()
        content = Path("Sources/TrackDownloader/Views/ContentView.swift").read_text()
        form = Path("Sources/TrackDownloader/Views/DownloadFormView.swift").read_text()
        source_card = Path("Sources/TrackDownloader/Views/SourcePreflightCard.swift").read_text()
        source_pane = Path("Sources/TrackDownloader/Views/SourcePaneView.swift").read_text()
        table = Path("Sources/TrackDownloader/Views/DownloadedTracksTable.swift").read_text()
        downloaded_tracks = Path("Sources/TrackDownloader/Views/DownloadedTracksView.swift").read_text()
        fixtures = Path("Sources/TrackDownloader/App/TrackDownloaderFixture.swift").read_text()
        settings = Path("Sources/TrackDownloader/Views/SettingsAboutView.swift").read_text()

        self.assertIn(".defaultSize(width: 1280, height: 760)", app)
        self.assertIn(".windowResizability(.automatic)", app)
        self.assertNotIn("NSApp.appearance", app)
        self.assertNotIn("initialDestination:", app)
        self.assertIn("HSplitView", content)
        self.assertIn("if case .idle = store.state", content)
        self.assertIn("DownloadedTracksView(store: downloadedTrackStore, selection: $selectedTrackURL)", content)
        self.assertIn("SourcePaneView", content)
        self.assertNotIn("TransferCard", content)
        self.assertNotIn("fixedSize(horizontal: true, vertical: true)", content)
        self.assertNotIn("NavigationSplitView", content)
        self.assertNotIn("LibrarySidebarView", content)
        self.assertNotIn("catalogueInitiallyExpanded", content)
        self.assertNotIn('Label("Open Library"', content)
        self.assertNotIn("DisclosureGroup", downloaded_tracks)
        self.assertIn("private var scopePicker: some View", downloaded_tracks)
        self.assertIn("private var catalogueControls: some View", downloaded_tracks)
        self.assertIn('Button("Open Downloads"', downloaded_tracks)
        self.assertIn("DownloadedTracksTable", downloaded_tracks)
        self.assertIn("NSTableView", table)
        self.assertIn("Move Earlier", downloaded_tracks)
        self.assertIn("Move Later", downloaded_tracks)
        self.assertIn("store.moveCatalogueColumn", downloaded_tracks)
        self.assertNotIn("initialDestination", fixtures)
        self.assertIn('Text("Source")', source_pane)
        self.assertIn('accessibilityLabel("Track link")', form)
        self.assertIn(
            "Paste a supported link to check its source before downloading.", form
        )
        self.assertIn(
            "Checking a valid YouTube or SoundCloud link contacts that platform. No media downloads until you choose Download.",
            form,
        )
        self.assertNotIn('Label("Download"', form)
        self.assertNotIn("Command-Return", form)
        self.assertNotIn("pasted(value)", form)
        self.assertNotIn(".onPasteCommand", form)
        self.assertIn('Button("Download"', source_card)
        self.assertIn('Button("Check again"', source_card)
        progress_view = Path("Sources/TrackDownloader/Views/DownloadProgressView.swift").read_text()
        self.assertIn("VUProgressMeter(", progress_view)
        self.assertLess(progress_view.index('Button("Cancel"'), progress_view.index("VUProgressMeter("))
        self.assertIn('keyboardShortcut(",", modifiers: .command)', source_pane)
        self.assertIn("Created by Jack Irvine", settings)
        self.assertIn("Copyright 2026 Jack Irvine", settings)
        self.assertIn("MIT License", settings)
        self.assertIn('Section("Appearance")', settings)
        self.assertIn('Picker("Appearance"', settings)
        self.assertEqual(settings.count("preference.title"), 1)
        self.assertIn("@AppStorage(AppearancePreference.storageKey)", app)
        self.assertIn(".preferredColorScheme(effectiveColorScheme)", app)
        self.assertIn("TrackDownloaderFixture.appearanceConfiguration.colorScheme ?? savedColorScheme", app)
        self.assertIn('static let storageKey = "TrackDownloaderAppearancePreference"', Path("Sources/TrackDownloader/Models/AppearancePreference.swift").read_text())
        self.assertNotIn(".preferredColorScheme(.dark)", app)
        self.assertIn('appearanceValue("TrackDownloaderAppearance")', fixtures)
        self.assertIn('case "idle", "focused", "typed":', fixtures)
        self.assertNotIn('case "catalogue-expanded"', fixtures)
        self.assertIn('case "collection-multiple"', fixtures)

    def test_inline_library_scope_and_state_wiring_is_persistence_safe(self) -> None:
        """Catch inline scope or deletion state changing independently of the store."""
        downloaded_tracks = Path("Sources/TrackDownloader/Views/DownloadedTracksView.swift").read_text()

        self.assertIn("@State private var destination: LibraryDestination = .allTracks", downloaded_tracks)
        self.assertIn("store.tracks(in: destination, matching: searchText, sortedBy: sort)", downloaded_tracks)
        self.assertIn("LibraryContentPresentation.resolve", downloaded_tracks)
        self.assertIn("case .unavailable", downloaded_tracks)
        self.assertIn("case .noMatches", downloaded_tracks)
        self.assertIn("case .empty", downloaded_tracks)
        self.assertIn(
            """if store.deleteCrate(cratePendingDeletion.id) {
                    if destination == .crate(cratePendingDeletion.id) {
                        destination = .allTracks
                    }
                }""",
            downloaded_tracks,
        )

    def test_split_view_is_the_source_and_library_workbench(self) -> None:
        """Catch any transfer state moving or duplicating the meter away from the library boundary."""
        content = Path("Sources/TrackDownloader/Views/ContentView.swift").read_text()
        self.assertIn("HSplitView", content)
        self.assertIn("SourcePaneView", content)
        self.assertIn("DownloadedTracksView(store: downloadedTrackStore, selection: $selectedTrackURL)", content)
        self.assertNotIn("VUProgressMeter(", content)

    def test_source_pane_has_no_dashboard_parent_chrome(self) -> None:
        source_pane = Path("Sources/TrackDownloader/Views/SourcePaneView.swift").read_text()
        self.assertIn("Color(nsColor: .windowBackgroundColor)", source_pane)
        self.assertNotIn("Dashboard", source_pane)

    def test_release_bundle_uses_track_downloader_identity(self) -> None:
        package = Path("Package.swift").read_text()
        build_script = Path("script/build_and_run.sh").read_text()
        install_script = Path("script/install_bundle.sh").read_text()
        icon_tool = Path("tools/make_app_icon.py").read_text()
        info = plistlib.loads(Path("Track Downloader.app/Contents/Info.plist").read_bytes())

        self.assertIn('.executable(name: "TrackDownloader", targets: ["TrackDownloader"])', package)
        self.assertIn('TRACK_DOWNLOADER_APP_NAME="TrackDownloader"', build_script)
        self.assertIn('TRACK_DOWNLOADER_PRODUCT_NAME="Track Downloader"', build_script)
        self.assertIn('TRACK_DOWNLOADER_BUNDLE_ID="com.jackirvine.trackdownloader"', build_script)
        self.assertNotIn("pkill", build_script)
        self.assertIn('TRACK_DOWNLOADER_PRODUCT_NAME="Track Downloader"', install_script)
        self.assertIn('TRACK_DOWNLOADER_BUNDLE_ID="com.jackirvine.trackdownloader"', install_script)
        self.assertIn('ROOT / "Track Downloader.app"', icon_tool)
        self.assertEqual(info["CFBundleName"], "Track Downloader")
        self.assertEqual(info["CFBundleDisplayName"], "Track Downloader")
        self.assertEqual(info["CFBundleIdentifier"], "com.jackirvine.trackdownloader")
        self.assertEqual(info["CFBundleExecutable"], "TrackDownloader")
        self.assertEqual(info["CFBundleShortVersionString"], "1.1.0")
        self.assertEqual(info["CFBundleVersion"], "20261008.1")

    def test_allowlisted_surface_has_no_retired_identity(self) -> None:
        retired_markers = (b"DJ" + b"DL", b"DJ" + b" DL")
        allowlist = Path("script/public_release_paths.txt").read_text(encoding="utf-8").splitlines()

        self.assertIn("Track Downloader.app/Contents/Info.plist", allowlist)
        self.assertIn("tests/test_track_downloader_identity.py", allowlist)
        self.assertNotIn("Sources/TrackDownloader/Views/InspectorPaneView.swift", allowlist)
        for path in (
            "Sources/TrackDownloader/Models/StableVersion.swift",
            "Sources/TrackDownloader/Models/UpdateRelease.swift",
            "Sources/TrackDownloader/Services/UpdateChecking.swift",
            "Sources/TrackDownloader/Stores/UpdateStore.swift",
            "Sources/TrackDownloader/Views/UpdateNoticeView.swift",
            "tests/TrackDownloaderTests/StableVersionTests.swift",
            "tests/TrackDownloaderTests/UpdateCheckingTests.swift",
            "tests/TrackDownloaderTests/UpdateStoreTests.swift",
            "tests/TrackDownloaderTests/UpdateNoticePresentationTests.swift",
        ):
            self.assertIn(path, allowlist)
        for relative_path in allowlist:
            encoded_path = relative_path.encode("utf-8").lower()
            contents = Path(relative_path).read_bytes().lower()
            for marker in retired_markers:
                self.assertNotIn(marker.lower(), encoded_path, relative_path)
                self.assertNotIn(marker.lower(), contents, relative_path)

    def test_update_notice_uses_one_shared_store_without_automatic_installation(self) -> None:
        app = Path("Sources/TrackDownloader/App/TrackDownloaderApp.swift").read_text()
        settings = Path("Sources/TrackDownloader/Views/SettingsAboutView.swift").read_text()
        checking = Path("Sources/TrackDownloader/Services/UpdateChecking.swift").read_text()

        self.assertIn("@StateObject private var updateStore", app)
        self.assertIn("UpdateNoticeView", app)
        self.assertIn("updateStore.beginAutomaticCheck()", app)
        self.assertEqual(app.count("updateStore: updateStore"), 3)
        self.assertIn("@ObservedObject var updateStore: UpdateStore", settings)
        self.assertIn('Button("Check for Updates")', settings)
        fixtures = Path("Sources/TrackDownloader/App/TrackDownloaderFixture.swift").read_text()
        self.assertIn('case "settings-update-checking":', fixtures)
        self.assertIn('case "settings-update-up-to-date":', fixtures)
        self.assertIn('case "settings-update-failure":', fixtures)
        self.assertIn("if TrackDownloaderFixture.isActive", app)
        self.assertIn("UpdateStore.fixture(status: status ?? .idle)", app)
        self.assertIn("static var isActive: Bool", fixtures)
        self.assertEqual(checking.count("https://api.github.com/repos/jackirvinee/track-downloader/releases/latest"), 1)
        self.assertNotIn('"Authorization"', checking)
        self.assertNotIn("URLSession.shared.download", checking)


if __name__ == "__main__":
    unittest.main()
