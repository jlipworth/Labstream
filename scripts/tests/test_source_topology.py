import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "Labstream.xcodeproj" / "project.pbxproj"
SOURCE_ROOT = ROOT / "Labstream"


def project_section(text: str, name: str) -> str:
    start = f"/* Begin {name} section */"
    end = f"/* End {name} section */"
    return text.split(start, 1)[1].split(end, 1)[0]


def object_blocks(section: str) -> dict[str, tuple[str, str]]:
    pattern = re.compile(
        r"\t\t([A-F0-9]{24}) /\* ([^*]+) \*/ = \{(.*?)\n\t\t\};",
        re.DOTALL,
    )
    return {name: (identifier, body) for identifier, name, body in pattern.findall(section)}


def production_root_records(section: str) -> dict[str, tuple[str, str]]:
    records: dict[str, tuple[str, str]] = {}
    for line in section.splitlines():
        if "isa = PBXFileSystemSynchronizedRootGroup" not in line or "path =" not in line:
            continue
        match = re.search(
            r"([A-F0-9]{24}) /\* ([^*]+) \*/ = .*?\bpath = \"?([^\";]+)\"?;",
            line,
        )
        if match:
            identifier, name, path = match.groups()
            records[name] = (identifier, path)
    return records


class SourceTopologyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project = PROJECT.read_text()
        cls.root_records = production_root_records(
            project_section(cls.project, "PBXFileSystemSynchronizedRootGroup")
        )
        cls.target_blocks = object_blocks(project_section(cls.project, "PBXNativeTarget"))

    def test_production_roots_are_non_overlapping(self) -> None:
        paths = {name: path for name, (_, path) in self.root_records.items()}
        self.assertNotIn("Labstream", paths.values())
        self.assertEqual(
            {paths[name] for name in ("Shared", "Downloads", "visionOS", "Mobile", "macOS", "tvOS")},
            {
                "Labstream/Shared",
                "Labstream/Capabilities/Downloads",
                "Labstream/Platforms/visionOS",
                "Labstream/Platforms/Mobile",
                "Labstream/Platforms/macOS",
                "Labstream/Platforms/tvOS",
            },
        )
        resolved = [(ROOT / path).resolve() for path in paths.values()]
        for index, path in enumerate(resolved):
            for other in resolved[index + 1 :]:
                self.assertFalse(path in other.parents or other in path.parents, (path, other))

    def test_each_product_owns_shared_and_exact_capabilities(self) -> None:
        root_ids = {name: identifier for name, (identifier, _) in self.root_records.items()}
        expected = {
            "Labstream": {root_ids["Shared"], root_ids["Downloads"], root_ids["visionOS"]},
            "LabstreamMobile": {root_ids["Shared"], root_ids["Downloads"], root_ids["Mobile"]},
            "LabstreamMac": {root_ids["Shared"], root_ids["Downloads"], root_ids["macOS"]},
            "LabstreamTV": {root_ids["Shared"], root_ids["tvOS"]},
        }
        for target, wanted in expected.items():
            body = self.target_blocks[target][1]
            membership = re.search(
                r"fileSystemSynchronizedGroups = \((.*?)\);", body, re.DOTALL
            ).group(1)
            actual = set(re.findall(r"\b([A-F0-9]{24})\b", membership))
            self.assertEqual(actual, wanted, target)
        self.assertNotIn(root_ids["Downloads"], expected["LabstreamTV"])

    def test_no_production_membership_exception_can_drift(self) -> None:
        section = project_section(
            self.project, "PBXFileSystemSynchronizedBuildFileExceptionSet"
        )
        production_ids = {
            self.target_blocks[name][0]
            for name in ("Labstream", "LabstreamMobile", "LabstreamMac", "LabstreamTV")
        }
        exception_targets = set(re.findall(r"\btarget = ([A-F0-9]{24})\b", section))
        self.assertTrue(production_ids.isdisjoint(exception_targets))

    def test_platform_sources_have_one_exclusive_home(self) -> None:
        expected = {
            "visionOS": (
                "App/Labstream.swift",
                "Player/CinemaAppRouting.swift",
                "Player/CustomCinemaMode.swift",
                "Player/VideoNowPlayingCoordinator.swift",
                "SharePlay/WatchTogetherActivity.swift",
                "SharePlay/WatchTogetherCoordinator.swift",
                "SharePlay/WatchTogetherJoinView.swift",
                "SharePlay/WatchTogetherMediaLookup.swift",
            ),
            "Mobile": (
                "App/LabstreamMobile.swift",
                "Player/MobilePlayerOrientationCoordinator.swift",
                "Player/MobilePlayerSystemCoordinator.swift",
            ),
            "macOS": (
                "App/LabstreamMac.swift",
                "App/MacAppDelegate.swift",
                "Player/MacPlayerPresentation.swift",
                "Player/MacPlayerSystemCoordinator.swift",
                "UI/MacSidebarPolicy.swift",
            ),
            "tvOS": (
                "App/LabstreamTV.swift",
                "Debug/TVInputEvidence.swift",
                "Debug/TVPlayerFixture.swift",
                "Debug/TVUIFixtureCatalog.swift",
                "Debug/TVUITestLaunchConfiguration.swift",
            ),
        }
        for owner, paths in expected.items():
            owner_root = SOURCE_ROOT / "Platforms" / owner
            for relative in paths:
                path = owner_root / relative
                self.assertTrue(path.is_file(), path)
                matches = list(SOURCE_ROOT.rglob(path.name))
                self.assertEqual(matches, [path], path.name)
                text = path.read_text()
                self.assertNotRegex(text, r"(?m)^#if os\(")

    def test_each_platform_root_has_exactly_one_entrypoint(self) -> None:
        shared_entrypoints = [
            path for path in (SOURCE_ROOT / "Shared").rglob("*.swift") if "@main" in path.read_text()
        ]
        self.assertEqual(shared_entrypoints, [])
        for owner in ("visionOS", "Mobile", "macOS", "tvOS"):
            entrypoints = [
                path
                for path in (SOURCE_ROOT / "Platforms" / owner).rglob("*.swift")
                if "@main" in path.read_text()
            ]
            self.assertEqual(len(entrypoints), 1, (owner, entrypoints))

    def test_download_and_spatial_capabilities_cannot_enter_tvos(self) -> None:
        downloads = SOURCE_ROOT / "Capabilities" / "Downloads"
        self.assertTrue((downloads / "Core" / "DownloadManager.swift").is_file())
        self.assertTrue((downloads / "App" / "AppDelegate.swift").is_file())
        self.assertFalse(any((SOURCE_ROOT / "Shared" / "Debug").glob("Debug*DownloadProbe.swift")))
        vision = SOURCE_ROOT / "Platforms" / "visionOS"
        self.assertTrue((vision / "Player" / "CustomCinemaMode.swift").is_file())
        self.assertTrue((vision / "Player" / "CinemaAppRouting.swift").is_file())
        self.assertEqual(len(list((vision / "SharePlay").glob("*.swift"))), 4)
        for owner in ("Mobile", "macOS", "tvOS"):
            names = {path.name for path in (SOURCE_ROOT / "Platforms" / owner).rglob("*.swift")}
            self.assertNotIn("CustomCinemaMode.swift", names)
            self.assertNotIn("CinemaAppRouting.swift", names)
            self.assertFalse(any("WatchTogether" in name for name in names))

    def test_cinema_app_tests_are_honest_about_missing_vision_host(self) -> None:
        tests = (ROOT / "LabstreamTests" / "CinemaAppRoutingTests.swift").read_text()
        self.assertTrue(tests.startswith("#if os(visionOS)\n"))
        matrix = json.loads((ROOT / "scripts" / "native-test-matrix.json").read_text())
        self.assertEqual(matrix["lanes"]["visionos-hosted"]["status"], "planned")


if __name__ == "__main__":
    unittest.main()
