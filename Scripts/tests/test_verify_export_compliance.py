#!/usr/bin/env python3
"""Tests for Scripts/verify-export-compliance.py with sample project files and app bundles."""
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "verify-export-compliance.py"
spec = importlib.util.spec_from_file_location("verify_export_compliance", SCRIPT)
vec = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vec)

PROJECT = """name: Pantrified
settings:
  base:
    MARKETING_VERSION: "0.1"
targets:
  Pantrified:
    type: application
    settings:
      base:
        PRODUCT_NAME: Pantrified
        INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: {value}
    dependencies:
      - package: Pantrified
  PantrifiedTests:
    type: bundle.unit-test
schemes:
  Pantrified:
    build: {{}}
"""


def project(value="NO"):
    return PROJECT.format(value=value)


class ProjectTests(unittest.TestCase):
    def test_no_passes(self):
        for value in ("NO", '"NO"', "'NO'", "NO  # owner's answer"):
            with self.subTest(value=value):
                self.assertEqual(vec.check_project(project(value)), [])

    def test_any_other_value_fails(self):
        for value in ("YES", "false", "no", '"YES"', "$(INHERITED)"):
            with self.subTest(value=value):
                errors = vec.check_project(project(value))
                self.assertEqual(len(errors), 1)
                self.assertIn("not NO", errors[0])

    def test_a_missing_setting_fails(self):
        text = project().replace("        INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO\n", "")
        self.assertEqual(vec.check_project(text),
                         ["the Pantrified target does not set INFOPLIST_KEY_ITSAppUsesNonExemptEncryption"])

    def test_a_setting_on_another_target_does_not_count(self):
        text = project().replace("        INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO\n", "")
        text = text.replace("    type: bundle.unit-test\n",
                            "    type: bundle.unit-test\n    settings:\n      INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO\n")
        self.assertTrue(vec.check_project(text))

    def test_a_repeated_setting_fails(self):
        text = project().replace("    dependencies:\n",
                                 "    configs:\n      Release:\n        INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: YES\n"
                                 "    dependencies:\n")
        self.assertIn("2 times", vec.check_project(text)[0])

    def test_a_project_without_the_target_fails(self):
        self.assertEqual(vec.check_project("name: X\ntargets:\n  Other:\n    type: application\n"),
                         ["project.yml has no Pantrified target"])

    def test_the_repository_project_passes(self):
        self.assertEqual(vec.check(SCRIPT.parent.parent / "project.yml"), [])


class BundleTests(unittest.TestCase):
    def check(self, info):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / "Pantrified.app"
            app.mkdir()
            if info is not None:
                (app / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
            return vec.check_bundle(app)

    def test_false_passes(self):
        self.assertEqual(self.check({"ITSAppUsesNonExemptEncryption": False}), [])

    def test_true_a_string_or_a_missing_key_fails(self):
        for info in ({"ITSAppUsesNonExemptEncryption": True}, {"ITSAppUsesNonExemptEncryption": "NO"},
                     {"CFBundleIdentifier": "x"}):
            with self.subTest(info=info):
                self.assertEqual(len(self.check(info)), 1)

    def test_a_missing_info_plist_fails(self):
        self.assertIn("cannot read", self.check(None)[0])


if __name__ == "__main__":
    unittest.main()
