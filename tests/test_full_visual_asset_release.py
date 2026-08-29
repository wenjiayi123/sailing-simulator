from __future__ import annotations

import json
from pathlib import Path
import unittest

from tools.audit_full_visual_release import build_report
from tools.build_full_visual_release import MEDIA_SUFFIXES, _selected_files


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "data/verification/visual_asset_release_manifest_v1.json"


class FullVisualAssetReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    def test_all_visual_media_is_registered_or_explicitly_local_only(self) -> None:
        report = build_report()
        self.assertTrue(report["summary"]["passed"], report["errors"])
        self.assertEqual(
            report["summary"]["included_asset_count"],
            len(self.manifest["included_assets"]),
        )
        self.assertEqual(report["summary"]["unregistered_media_count"], 0)
        self.assertEqual(report["summary"]["unresolved_included_asset_count"], 0)

    def test_included_assets_are_hash_and_rights_bound(self) -> None:
        report = build_report()
        for item in report["included_assets"]:
            self.assertTrue(all(item["checks"].values()), item)
        self.assertTrue(report["claims"]["all_included_media_hash_bound"])

    def test_runtime_has_no_reference_to_excluded_legacy_assets(self) -> None:
        report = build_report()
        self.assertEqual(report["runtime_excluded_references"], [])
        self.assertTrue(report["claims"]["excluded_local_assets_not_runtime_referenced"])

    def test_old_assets_are_retained_but_excluded_from_release(self) -> None:
        self.assertTrue((ROOT / "characters/download.png").is_file())
        self.assertTrue((ROOT / "assets/art/terrain/premium_reference_cliff_rock_32471782690108.jpg").is_file())
        self.assertTrue((ROOT / "assets/ui/xiaoyi/xiaoyi-maritime-officer.png").is_file())
        report = build_report()
        excluded = set(report["excluded_local_assets_present_but_not_referenced"])
        self.assertIn("characters/download.png", excluded)
        self.assertIn("assets/art/terrain/premium_reference_cliff_rock_32471782690108.jpg", excluded)
        self.assertFalse(any(path.startswith("草稿/") for path in excluded))

    def test_project_authored_svg_replacements_are_self_contained(self) -> None:
        generated = [
            row for row in self.manifest["included_assets"]
            if row["path"].startswith("assets/generated/release/")
        ]
        self.assertEqual(len(generated), 10)
        for row in generated:
            text = (ROOT / row["path"]).read_text(encoding="utf-8").lower()
            self.assertIn("<title>", text, row["path"])
            self.assertNotIn("<image", text, row["path"])
            self.assertNotIn("xlink:href", text, row["path"])

    def test_full_visual_bundle_selection_excludes_every_local_only_asset(self) -> None:
        selected = {
            path.relative_to(ROOT).as_posix() for path in _selected_files()
        }
        included_media = {row["path"] for row in self.manifest["included_assets"]}
        packaged_media = {
            relative for relative in selected
            if Path(relative).suffix.lower() in MEDIA_SUFFIXES
        }
        self.assertEqual(packaged_media, included_media)
        self.assertFalse(any(relative.startswith("characters/") for relative in selected))
        self.assertNotIn("icon.svg", selected)
        self.assertNotIn("assets/ui/xiaoyi/xiaoyi-maritime-officer.png", selected)

    def test_release_boundary_preserves_ship_model_policies_and_authority(self) -> None:
        claims = self.manifest["claims"]
        self.assertFalse(claims["named_vessel_dynamics_changed"])
        self.assertFalse(claims["existing_policy_artifacts_changed"])
        self.assertFalse(claims["production_authority"])
        source = (ROOT / "tools/build_full_visual_release.py").read_text(encoding="utf-8")
        self.assertNotIn("set_ship_agent_command", source)
        self.assertNotIn("train", source.lower())


if __name__ == "__main__":
    unittest.main()
