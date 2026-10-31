#!/usr/bin/env python3
"""Tests for Scripts/verify-app-icon.py with synthetic icon sets and app bundles."""
import importlib.util
import json
import pathlib
import plistlib
import struct
import tempfile
import unittest
import zlib

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "verify-app-icon.py"
spec = importlib.util.spec_from_file_location("verify_app_icon", SCRIPT)
va = importlib.util.module_from_spec(spec)
spec.loader.exec_module(va)

CONTENTS = {"images": [{"filename": "Icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]}


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def png(width=1024, height=1024, color_type=2, transparency=False):
    channels = {0: 1, 2: 3, 4: 2, 6: 4}[color_type]
    rows = b"".join(b"\x00" + bytes(width * channels) for _ in range(height))
    extra = chunk(b"tRNS", b"\x00\x00") if transparency else b""
    header = struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)
    return va.PNG_SIGNATURE + chunk(b"IHDR", header) + extra + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def check(image=None, contents=CONTENTS, bundle=None, plist=None, catalog=True):
    with tempfile.TemporaryDirectory() as directory:
        base = pathlib.Path(directory)
        iconset = base / "AppIcon.appiconset"
        iconset.mkdir()
        if contents is not None:
            (iconset / "Contents.json").write_text(contents if isinstance(contents, str) else json.dumps(contents))
        if image is not None:
            (iconset / "Icon.png").write_bytes(image)
        app = None
        if bundle:
            app = base / "App.app"
            app.mkdir()
            if catalog:
                (app / "Assets.car").write_bytes(b"car")
            if plist is not None:
                (app / "Info.plist").write_bytes(plistlib.dumps(plist, fmt=plistlib.FMT_BINARY))
        return va.check(iconset, app)


class SourceTests(unittest.TestCase):
    def test_a_1024_rgb_png_passes(self):
        self.assertEqual(check(png()), [])

    def test_a_grayscale_png_passes(self):
        self.assertEqual(check(png(color_type=0)), [])

    def test_the_wrong_size_fails(self):
        for size in [(512, 512), (1024, 1023), (1025, 1024)]:
            with self.subTest(size=size):
                errors = check(png(*size))
                self.assertEqual(len(errors), 1)
                self.assertIn("not 1024 by 1024", errors[0])

    def test_an_alpha_channel_fails(self):
        for color_type in (4, 6):
            with self.subTest(color_type=color_type):
                self.assertIn("Icon.png has an alpha channel", check(png(color_type=color_type)))

    def test_a_transparency_chunk_fails(self):
        self.assertIn("Icon.png has a transparency chunk", check(png(transparency=True)))

    def test_a_file_that_is_not_a_png_fails(self):
        self.assertIn("Icon.png is not a PNG file", check(b"GIF89a"))

    def test_a_truncated_png_fails(self):
        self.assertTrue(check(va.PNG_SIGNATURE))

    def test_a_named_file_that_is_missing_fails(self):
        self.assertIn("Icon.png is named in Contents.json but missing", check(None))

    def test_contents_that_name_no_file_fail(self):
        self.assertIn("Contents.json names no icon file", check(png(), {"images": [{"idiom": "universal"}]}))
        self.assertIn("Contents.json names no icon file", check(png(), {"images": []}))

    def test_contents_without_an_images_list_fail(self):
        self.assertIn("Contents.json has no images list", check(png(), {"info": {}}))
        self.assertIn("Contents.json has no images list", check(png(), []))

    def test_unreadable_contents_fail(self):
        self.assertTrue(check(png(), "{not json"))
        self.assertTrue(check(png(), None))


class BundleTests(unittest.TestCase):
    GOOD = {"CFBundleIconName": "AppIcon"}

    def test_a_bundle_with_the_catalog_and_icon_name_passes(self):
        self.assertEqual(check(png(), bundle=True, plist=self.GOOD), [])

    def test_a_missing_catalog_fails(self):
        errors = check(png(), bundle=True, plist=self.GOOD, catalog=False)
        self.assertEqual(len(errors), 1)
        self.assertIn("Assets.car", errors[0])

    def test_the_primary_icon_in_cfbundleicons_passes(self):
        plist = {"CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}}}
        self.assertEqual(check(png(), bundle=True, plist=plist), [])

    def test_a_missing_or_wrong_icon_name_fails(self):
        wrong_primary = {"CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "Other"}}}
        for plist in [{}, {"CFBundleIconName": "Other"}, wrong_primary, {"CFBundleIcons": {"CFBundlePrimaryIcon": "AppIcon"}}, {"CFBundleIcons": []}]:
            with self.subTest(plist=plist):
                errors = check(png(), bundle=True, plist=plist)
                self.assertEqual(len(errors), 1)
                self.assertIn("does not name the icon 'AppIcon'", errors[0])

    def test_the_error_lists_the_icon_keys_that_are_present(self):
        errors = check(png(), bundle=True, plist={"CFBundleIconFile": "x", "CFBundleName": "y"})
        self.assertIn("CFBundleIconFile", errors[0])
        self.assertNotIn("CFBundleName", errors[0])

    def test_a_missing_info_plist_fails(self):
        self.assertTrue(check(png(), bundle=True, plist=None))

    def test_a_bad_source_fails_even_when_the_bundle_is_good(self):
        self.assertTrue(check(png(512, 512), bundle=True, plist=self.GOOD))

    def test_a_missing_bundle_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            iconset = pathlib.Path(directory) / "AppIcon.appiconset"
            iconset.mkdir()
            (iconset / "Contents.json").write_text(json.dumps(CONTENTS))
            (iconset / "Icon.png").write_bytes(png())
            errors = va.check(iconset, pathlib.Path(directory) / "Nope.app")
        self.assertEqual(errors, [f"no such app bundle: {pathlib.Path(directory) / 'Nope.app'}"])


class RepositoryIconTests(unittest.TestCase):
    def test_the_icon_in_the_repository_passes(self):
        iconset = SCRIPT.parent.parent / "App" / "Assets.xcassets" / "AppIcon.appiconset"
        self.assertEqual(va.check(iconset, None), [])


if __name__ == "__main__":
    unittest.main()
