#!/usr/bin/env python3
"""Tests for Scripts/verify-privacy-manifest.py with synthetic manifests and app bundles."""
import copy
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "verify-privacy-manifest.py"
spec = importlib.util.spec_from_file_location("verify_privacy_manifest", SCRIPT)
vp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vp)

VALID = {
    "NSPrivacyTracking": False,
    "NSPrivacyTrackingDomains": [],
    "NSPrivacyCollectedDataTypes": [],
    "NSPrivacyAccessedAPITypes": [],
}

COLLECTED = {
    "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeProductInteraction",
    "NSPrivacyCollectedDataTypeLinked": False,
    "NSPrivacyCollectedDataTypeTracking": False,
    "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
}


def check(plist, bundle=None, binary=False):
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        source = base / "PrivacyInfo.xcprivacy"
        source.write_bytes(plistlib.dumps(plist))
        app = None
        if bundle is not None:
            app = base / "App.app"
            app.mkdir()
            if bundle is not False:
                fmt = plistlib.FMT_BINARY if binary else plistlib.FMT_XML
                (app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(bundle, fmt=fmt))
        return vp.check(source, app)


def with_(**changes):
    plist = copy.deepcopy(VALID)
    plist.update(changes)
    return plist


class SourceTests(unittest.TestCase):
    def test_a_valid_manifest_passes(self):
        self.assertEqual(check(VALID), [])

    def test_a_manifest_with_a_collected_data_type_passes(self):
        self.assertEqual(check(with_(NSPrivacyCollectedDataTypes=[COLLECTED])), [])

    def test_each_required_key_must_be_present(self):
        for key in VALID:
            with self.subTest(key=key):
                plist = copy.deepcopy(VALID)
                del plist[key]
                self.assertTrue(check(plist))

    def test_values_must_have_the_right_types(self):
        for key, bad in [("NSPrivacyTracking", "no"), ("NSPrivacyTrackingDomains", "x.com"),
                         ("NSPrivacyCollectedDataTypes", {}), ("NSPrivacyAccessedAPITypes", "none")]:
            with self.subTest(key=key):
                self.assertTrue(check(with_(**{key: bad})))

    def test_tracking_needs_domains_and_domains_need_tracking(self):
        self.assertTrue(check(with_(NSPrivacyTracking=True)))
        self.assertTrue(check(with_(NSPrivacyTrackingDomains=["track.example.com"])))
        self.assertEqual(check(with_(NSPrivacyTracking=True, NSPrivacyTrackingDomains=["track.example.com"])), [])

    def test_a_collected_data_type_needs_every_field_and_a_purpose(self):
        for key in COLLECTED:
            with self.subTest(key=key):
                broken = copy.deepcopy(COLLECTED)
                del broken[key]
                self.assertTrue(check(with_(NSPrivacyCollectedDataTypes=[broken])))
        empty = copy.deepcopy(COLLECTED)
        empty["NSPrivacyCollectedDataTypePurposes"] = []
        self.assertTrue(check(with_(NSPrivacyCollectedDataTypes=[empty])))

    def test_an_accessed_api_type_needs_a_name_and_a_reason(self):
        good = {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]}
        self.assertEqual(check(with_(NSPrivacyAccessedAPITypes=[good])), [])
        self.assertTrue(check(with_(NSPrivacyAccessedAPITypes=[{**good, "NSPrivacyAccessedAPITypeReasons": []}])))
        self.assertTrue(check(with_(NSPrivacyAccessedAPITypes=[{"NSPrivacyAccessedAPITypeReasons": ["CA92.1"]}])))

    def test_a_file_that_is_not_a_property_list_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "PrivacyInfo.xcprivacy"
            path.write_text("not a plist")
            self.assertTrue(vp.check(path, None))

    def test_a_missing_manifest_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertTrue(vp.check(pathlib.Path(directory) / "none", None))


class BundleTests(unittest.TestCase):
    def test_a_bundle_with_the_same_manifest_passes_in_xml_or_binary(self):
        self.assertEqual(check(VALID, bundle=VALID), [])
        self.assertEqual(check(VALID, bundle=VALID, binary=True), [])

    def test_a_bundle_without_the_manifest_is_an_error(self):
        self.assertTrue(check(VALID, bundle=False))

    def test_a_bundle_whose_manifest_differs_is_an_error(self):
        self.assertTrue(check(VALID, bundle=with_(NSPrivacyTracking=True, NSPrivacyTrackingDomains=["a.example.com"])))

    def test_a_missing_bundle_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            base = pathlib.Path(directory)
            source = base / "PrivacyInfo.xcprivacy"
            source.write_bytes(plistlib.dumps(VALID))
            self.assertTrue(vp.check(source, base / "Missing.app"))


if __name__ == "__main__":
    unittest.main()
