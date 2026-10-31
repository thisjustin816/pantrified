#!/usr/bin/env python3
"""Tests for Scripts/testflight-project.py with sample generated projects."""
import base64
import contextlib
import gzip
import hashlib
import importlib.util
import io
import os
import pathlib
import tarfile
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parent.parent / "testflight-project.py"
spec = importlib.util.spec_from_file_location("testflight_project", SCRIPT)
tp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tp)

PBXPROJ = """// !$*UTF8*$!
{
	objects = {
		1 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; };
		2 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");
				OTHER_LDFLAGS = "-ObjC";
				PRODUCT_BUNDLE_IDENTIFIER = "com.thisjustin816.Pantrified$(BUNDLE_ID_SUFFIX)";
			};
		};
	};
}
"""
SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme version = "1.7">
   <BuildAction parallelizeBuildables = "YES"></BuildAction>
</Scheme>
"""


def make_project(base, pbxproj=PBXPROJ, scheme=SCHEME, extra=None):
    project = pathlib.Path(base) / "Pantrified.xcodeproj"
    (project / "project.xcworkspace").mkdir(parents=True)
    (project / "xcshareddata" / "xcschemes").mkdir(parents=True)
    (project / "project.pbxproj").write_text(pbxproj)
    (project / "project.xcworkspace" / "contents.xcworkspacedata").write_text("<Workspace/>")
    (project / "xcshareddata" / "xcschemes" / "Pantrified.xcscheme").write_text(scheme)
    for name, text in (extra or {}).items():
        (project / name).parent.mkdir(parents=True, exist_ok=True)
        (project / name).write_text(text)
    return project


def archive_of(entries):
    """Builds a packed project from (name, kind, data) entries, to test what unpack refuses."""
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, kind, data in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            if kind == tarfile.SYMTYPE:
                info.linkname = data
                archive.addfile(info)
            elif kind == tarfile.DIRTYPE:
                archive.addfile(info)
            else:
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
    compressed = gzip.compress(buffer.getvalue(), mtime=0)
    return base64.b64encode(compressed).decode(), hashlib.sha256(compressed).hexdigest()


class CheckTests(unittest.TestCase):
    def check(self, **kwargs):
        with tempfile.TemporaryDirectory() as directory:
            return tp.check(make_project(directory, **kwargs))

    def test_a_plain_project_passes(self):
        self.assertEqual(self.check(), [])

    def test_constructs_that_run_commands_fail(self):
        for marker in ("PBXShellScriptBuildPhase", "PBXBuildRule", "PBXLegacyTarget"):
            with self.subTest(marker=marker):
                problems = self.check(pbxproj=PBXPROJ.replace("PBXSourcesBuildPhase", marker))
                self.assertEqual(len(problems), 1, problems)
        for marker in ("<PreActions>", "<PostActions>", "Xcode.IDEStandardExecutionActionsCore.ShellScriptAction"):
            with self.subTest(marker=marker):
                problems = self.check(scheme=SCHEME.replace("</BuildAction>", marker + "</BuildAction>"))
                self.assertTrue(problems)

    def test_replacement_build_tools_fail(self):
        for setting in ("CC = /tmp/cc;", '"LD[sdk=iphoneos*]" = /tmp/ld;', "SWIFT_EXEC = /tmp/swiftc;",
                        "LDPLUSPLUS = x;", "CLANG_ANALYZER_EXEC = x;", "CLANG_TOOL_PATH = x;"):
            with self.subTest(setting=setting):
                text = PBXPROJ.replace('OTHER_LDFLAGS = "-ObjC";', setting)
                self.assertIn("replaces a build tool", self.check(pbxproj=text)[0])

    def test_compiler_plugin_flags_fail(self):
        for flag in tp.PLUGIN_FLAGS:
            with self.subTest(flag=flag):
                text = PBXPROJ.replace('"-ObjC"', f'"{flag} /tmp/p"')
                self.assertIn("plugin flag", self.check(pbxproj=text)[0])

    def test_unexpected_files_fail(self):
        self.assertTrue(self.check(extra={"Signing.xcconfig": "CODE_SIGN_STYLE = Manual"}))
        self.assertTrue(self.check(extra={"xcuserdata/me.xcuserdatad/x.plist": "x"}))

    def test_a_symbolic_link_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            project = make_project(directory)
            os.symlink("/etc/passwd", project / "link")
            self.assertEqual(tp.check(project), ["link is a symbolic link"])

    def test_a_directory_without_a_project_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertTrue(tp.check(directory))


class PackTests(unittest.TestCase):
    def test_pack_and_unpack_round_trip(self):
        with tempfile.TemporaryDirectory() as source, tempfile.TemporaryDirectory() as target:
            project = make_project(source)
            encoded, digest = tp.pack(project)
            destination = pathlib.Path(target) / "Pantrified.xcodeproj"
            tp.unpack(destination, encoded, digest)
            for path in project.rglob("*"):
                copy = destination / path.relative_to(project)
                self.assertEqual(path.is_dir(), copy.is_dir())
                if path.is_file():
                    self.assertEqual(path.read_bytes(), copy.read_bytes())

    def test_packing_is_reproducible(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            self.assertEqual(tp.pack(make_project(first)), tp.pack(make_project(second)))

    def test_a_wrong_digest_or_bad_base64_is_refused(self):
        with tempfile.TemporaryDirectory() as source, tempfile.TemporaryDirectory() as target:
            encoded, digest = tp.pack(make_project(source))
            destination = pathlib.Path(target) / "Pantrified.xcodeproj"
            with self.assertRaises(tp.Failure):
                tp.unpack(destination, encoded, "0" * 64)
            with self.assertRaises(tp.Failure):
                tp.unpack(destination, "%%%", digest)
            self.assertFalse(destination.exists())

    def test_unsafe_entries_are_refused(self):
        for name in ("parent", "absolute", "other root", "symlink", "device"):
            # The project goes two levels down, so an entry that escapes still lands inside the
            # temporary directory, where the test can see it.
            with self.subTest(case=name), tempfile.TemporaryDirectory() as base:
                entries = {
                    "parent": [("Pantrified.xcodeproj/../../evil", tarfile.REGTYPE, b"x")],
                    "absolute": [(f"{base}/evil", tarfile.REGTYPE, b"x")],
                    "other root": [("Other.xcodeproj/evil", tarfile.REGTYPE, b"x")],
                    "symlink": [("Pantrified.xcodeproj/evil", tarfile.SYMTYPE, "/etc/passwd")],
                    "device": [("Pantrified.xcodeproj/evil", tarfile.CHRTYPE, b"")],
                }[name]
                encoded, digest = archive_of(entries)
                target = pathlib.Path(base) / "a" / "b"
                target.mkdir(parents=True)
                with self.assertRaises(tp.Failure):
                    tp.unpack(target / "Pantrified.xcodeproj", encoded, digest)
                self.assertEqual(list(pathlib.Path(base).rglob("evil")), [])

    def test_an_existing_destination_is_refused(self):
        with tempfile.TemporaryDirectory() as source:
            project = make_project(source)
            encoded, digest = tp.pack(project)
            with self.assertRaises(tp.Failure):
                tp.unpack(project, encoded, digest)

    def test_the_commands_pass_the_project_through_outputs_and_the_environment(self):
        with tempfile.TemporaryDirectory() as source, tempfile.TemporaryDirectory() as target:
            project = make_project(source)
            output = pathlib.Path(source) / "output"
            with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(tp.main(["pack", str(project)]), 0)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            destination = pathlib.Path(target) / "Pantrified.xcodeproj"
            environment = {"PROJECT_ARCHIVE": values["project"], "PROJECT_SHA256": values["project_sha256"]}
            with mock.patch.dict(os.environ, environment), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(tp.main(["unpack", str(destination)]), 0)
            self.assertEqual((destination / "project.pbxproj").read_text(), PBXPROJ)

    def test_pack_refuses_a_project_that_fails_the_check(self):
        with tempfile.TemporaryDirectory() as source:
            project = make_project(source, pbxproj=PBXPROJ.replace("PBXSourcesBuildPhase", "PBXShellScriptBuildPhase"))
            output = pathlib.Path(source) / "output"
            with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(tp.main(["pack", str(project)]), 1)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
