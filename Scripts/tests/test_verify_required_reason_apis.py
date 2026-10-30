#!/usr/bin/env python3
"""Tests for Scripts/verify-required-reason-apis.py with synthetic sources and manifests."""
import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "verify-required-reason-apis.py"
spec = importlib.util.spec_from_file_location("verify_required_reason_apis", SCRIPT)
vr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vr)

FILE_TIMESTAMP = "NSPrivacyAccessedAPICategoryFileTimestamp"
USER_DEFAULTS = "NSPrivacyAccessedAPICategoryUserDefaults"
BOOT_TIME = "NSPrivacyAccessedAPICategorySystemBootTime"
DISK_SPACE = "NSPrivacyAccessedAPICategoryDiskSpace"
KEYBOARDS = "NSPrivacyAccessedAPICategoryActiveKeyboards"


def manifest(*declared):
    return {
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyCollectedDataTypes": [],
        "NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": category, "NSPrivacyAccessedAPITypeReasons": reasons}
            for category, reasons in declared
        ],
    }


class Tree:
    """A throwaway source tree and manifest on disk."""

    def __init__(self, files, plist):
        self.dir = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.dir.name) / "Sources"
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        self.manifest = pathlib.Path(self.dir.name) / "PrivacyInfo.xcprivacy"
        self.manifest.write_bytes(plistlib.dumps(plist))

    def run(self):
        return vr.check(self.manifest, [self.root])

    def close(self):
        self.dir.cleanup()


def run(files, plist):
    tree = Tree(files, plist)
    try:
        return tree.run()
    finally:
        tree.close()


class DetectionTests(unittest.TestCase):
    def test_each_category_is_detected(self):
        cases = {
            USER_DEFAULTS: ["let d = UserDefaults.standard", "@AppStorage(\"k\") var x = 1", "NSUserDefaults.standardUserDefaults"],
            FILE_TIMESTAMP: ["let d = attrs[.modificationDate]", "try url.resourceValues(forKeys: [.contentModificationDateKey])",
                             "let a = try fm.attributesOfItem(atPath: p)", "var s = stat(); stat(path, &s)"],
            BOOT_TIME: ["let t = ProcessInfo.processInfo.systemUptime", "let t = mach_absolute_time()"],
            DISK_SPACE: ["keys: [.volumeAvailableCapacityKey]", "let free = attrs[.systemFreeSize]", "statfs(path, &fs)"],
            KEYBOARDS: ["let modes = UITextInputMode.activeInputModes"],
        }
        for category, lines in cases.items():
            for line in lines:
                with self.subTest(category=category, line=line):
                    result = run({"A.swift": line + "\n"}, manifest((category, ["X.1"])))
                    self.assertEqual(result.errors, [])
                    self.assertIn(category, result.used)

    def test_code_in_comments_and_strings_is_not_a_use(self):
        source = '''
        // UserDefaults is not used here
        /* mach_absolute_time() would be a boot time use */
        let note = "call UserDefaults.standard later"
        let multi = """
        systemUptime
        """
        let url = "https://example.com/stat(x)" // trailing UserDefaults mention
        '''
        result = run({"A.swift": source}, manifest())
        self.assertEqual(result.used, {})
        self.assertEqual(result.errors, [])

    def test_a_word_that_merely_contains_a_name_is_not_a_use(self):
        result = run({"A.swift": "let status = 1\nlet restat = 2\nlet myUserDefaultsLike = 3\n"}, manifest())
        self.assertEqual(result.used, {})

    def test_only_swift_files_are_read(self):
        result = run({"notes.md": "UserDefaults.standard", "A.swift": "let a = 1\n"}, manifest())
        self.assertEqual(result.used, {})

    def test_evidence_names_the_file_and_line(self):
        result = run({"Sub/A.swift": "let a = 1\nlet d = UserDefaults.standard\n"}, manifest((USER_DEFAULTS, ["CA92.1"])))
        file, line = result.used[USER_DEFAULTS][0]
        self.assertTrue(file.endswith("A.swift"))
        self.assertEqual(line, 2)


class ComparisonTests(unittest.TestCase):
    def test_a_use_the_manifest_does_not_declare_is_an_error(self):
        result = run({"A.swift": "let d = UserDefaults.standard\n"}, manifest())
        self.assertEqual(len(result.errors), 1)
        self.assertIn(USER_DEFAULTS, result.errors[0])
        self.assertIn("not declared", result.errors[0])

    def test_a_declaration_the_code_does_not_use_is_an_error(self):
        result = run({"A.swift": "let a = 1\n"}, manifest((BOOT_TIME, ["35F9.1"])))
        self.assertEqual(len(result.errors), 1)
        self.assertIn("not used", result.errors[0])

    def test_a_declaration_without_a_reason_is_an_error(self):
        result = run({"A.swift": "let d = UserDefaults.standard\n"}, manifest((USER_DEFAULTS, [])))
        self.assertTrue(any("reason" in error for error in result.errors))

    def test_a_matching_manifest_passes(self):
        result = run({"A.swift": "let d = UserDefaults.standard\n"}, manifest((USER_DEFAULTS, ["CA92.1"])))
        self.assertEqual(result.errors, [])

    def test_an_empty_manifest_and_clean_code_pass(self):
        self.assertEqual(run({"A.swift": "let a = 1\n"}, manifest()).errors, [])

    def test_a_missing_manifest_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            result = vr.check(pathlib.Path(directory) / "none.xcprivacy", [pathlib.Path(directory)])
        self.assertTrue(result.errors)

    def test_an_unknown_declared_category_is_an_error(self):
        result = run({"A.swift": "let a = 1\n"}, manifest(("NSPrivacyAccessedAPICategoryMadeUp", ["X.1"])))
        self.assertTrue(any("unknown" in error for error in result.errors))


if __name__ == "__main__":
    unittest.main()
