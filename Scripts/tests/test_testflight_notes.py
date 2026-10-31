#!/usr/bin/env python3
"""Tests for Scripts/testflight-notes.py, Scripts/changelog.py and Scripts/appstoreconnect.py."""
import base64
import contextlib
import importlib.util
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

SCRIPTS = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS))
import appstoreconnect  # noqa: E402
import changelog  # noqa: E402

spec = importlib.util.spec_from_file_location("testflight_notes", SCRIPTS / "testflight-notes.py")
notes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notes)


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


class Repository:
    """A throwaway repository whose history the notes are written from."""

    def __init__(self, directory):
        self.path = pathlib.Path(directory)
        git(self.path, "init", "-q", "-b", "main")
        git(self.path, "config", "user.name", "Test")
        git(self.path, "config", "user.email", "test@example.com")

    def commit(self, message, path="App/File.swift", text=None):
        file = self.path / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text if text is not None else message)
        git(self.path, "add", "-A")
        git(self.path, "commit", "-q", "-m", message)
        return git(self.path, "rev-parse", "HEAD")


class NotesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.repo = Repository(self.directory.name)
        self.previous = os.getcwd()
        os.chdir(self.repo.path)

    def tearDown(self):
        os.chdir(self.previous)
        self.directory.cleanup()

    def write(self, sha, branch="main", variant="release"):
        output = self.repo.path.parent / f"{self.repo.path.name}-notes.txt"
        github_output = self.repo.path.parent / f"{self.repo.path.name}-output"
        github_output.write_text("")
        with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(github_output)}), \
                contextlib.redirect_stdout(io.StringIO()):
            notes.main(["notes", "--sha", sha, "--branch", branch, "--variant", variant, "--output", str(output)])
        return output.read_text(), github_output.read_text().strip()

    def test_the_first_main_upload_lists_recent_changes(self):
        self.repo.commit("Add the pantry")
        sha = self.repo.commit("Add the shopping list")
        text, output = self.write(sha)
        self.assertIn("Recent changes:", text)
        self.assertIn("- Add the shopping list", text)
        self.assertEqual(output, "app_changed=true")

    def test_a_main_upload_lists_changes_since_the_previous_upload_tag(self):
        tagged = self.repo.commit("Add the pantry")
        git(self.repo.path, "tag", "testflight/12", tagged)
        sha = self.repo.commit("Add the shopping list")
        text, output = self.write(sha)
        self.assertIn("Changes since build 12:", text)
        self.assertIn("- Add the shopping list", text)
        self.assertNotIn("Add the pantry", text)
        self.assertEqual(output, "app_changed=true")

    def test_a_push_of_docs_or_workflows_only_changes_no_app(self):
        tagged = self.repo.commit("Add the pantry")
        git(self.repo.path, "tag", "testflight/12", tagged)
        self.repo.commit("Explain the pantry", path="docs/pantry.md")
        self.repo.commit("Change a workflow", path=".github/workflows/ci.yml")
        sha = self.repo.commit("Edit the README", path="README.md")
        _, output = self.write(sha)
        self.assertEqual(output, "app_changed=false")

    def test_a_change_to_a_script_or_the_project_changes_the_app(self):
        for path in ("Scripts/upload-testflight.sh", "project.yml", "App/RootView.swift", "Package.swift"):
            with self.subTest(path=path):
                tagged = self.repo.commit(f"Before {path}")
                git(self.repo.path, "tag", "-f", "testflight/12", tagged)
                sha = self.repo.commit(f"Change {path}", path=path)
                self.assertEqual(self.write(sha)[1], "app_changed=true")

    def test_a_branch_build_lists_the_branch_commits(self):
        self.repo.commit("Add the pantry")
        git(self.repo.path, "update-ref", "refs/remotes/origin/main", "HEAD")
        git(self.repo.path, "checkout", "-q", "-b", "feature/x")
        sha = self.repo.commit("Try a new list")
        text, output = self.write(sha, branch="feature/x")
        self.assertIn("Branch feature/x at", text)
        self.assertIn("not yet on main", text)
        self.assertIn("- Try a new list", text)
        self.assertNotIn("Add the pantry", text)
        self.assertEqual(output, "app_changed=true")

    def test_an_evaluation_build_says_so_first(self):
        sha = self.repo.commit("Add the pantry")
        text, _ = self.write(sha, variant="evaluation")
        self.assertTrue(text.startswith("Evaluation build: the Evaluation tab is compiled in. Internal testers only."))
        self.assertNotIn("Evaluation build", self.write(sha)[0])

    def test_a_merged_pull_request_is_listed_by_its_title(self):
        self.repo.commit("Start")
        git(self.repo.path, "checkout", "-q", "-b", "topic")
        self.repo.commit("Work in progress")
        git(self.repo.path, "checkout", "-q", "main")
        git(self.repo.path, "merge", "-q", "--no-ff", "topic", "-m",
            "Merge pull request #15 from owner/topic\n\nShow how much is left")
        text, _ = self.write(git(self.repo.path, "rev-parse", "HEAD"))
        self.assertIn("- Show how much is left (#15)", text)
        self.assertNotIn("Work in progress", text)


class FitTests(unittest.TestCase):
    def test_notes_stay_within_apples_limit(self):
        titles = [f"Change number {index} " + "x" * 80 for index in range(200)]
        text = changelog.fit("Header", titles)
        self.assertLessEqual(len(text), changelog.MAX_NOTES)
        self.assertRegex(text.splitlines()[-1], r"^- \.\.\.and \d+ more$")

    def test_short_notes_are_kept_whole(self):
        self.assertEqual(changelog.fit("Header", ["One", "Two"]), "Header\n- One\n- Two")


class FakeClient:
    def __init__(self, answers):
        self.answers = list(answers)
        self.requests = []
        self.notes = None

    def app_id(self):
        return "6829003513"

    def request(self, method, path, body=None):
        self.requests.append((method, path))
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer

    def set_whats_new(self, build_id, text):
        self.notes = (build_id, text)


class PublishTests(unittest.TestCase):
    def args(self, wait_minutes=0):
        return mock.Mock(version="0.1", build="57", wait_minutes=wait_minutes)

    def test_the_notes_are_set_on_the_matching_build(self):
        client = FakeClient([{"data": [{"id": "build-1"}]}])
        with contextlib.redirect_stdout(io.StringIO()):
            notes.publish_build_notes(client, self.args(), "What changed")
        self.assertEqual(client.notes, ("build-1", "What changed"))
        method, path = client.requests[0]
        self.assertEqual(method, "GET")
        self.assertIn("filter[app]=6829003513", path)
        self.assertIn("filter[version]=57", path)
        self.assertIn("filter[preReleaseVersion.version]=0.1", path)

    def test_it_waits_for_the_build_then_gives_up(self):
        client = FakeClient([{"data": []}, {"data": []}])
        with mock.patch.object(notes.time, "sleep"), mock.patch.object(notes.time, "monotonic", side_effect=[0, 0, 1]), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as raised:
            notes.publish_build_notes(client, self.args(), "text")
        self.assertIn("Gave up", str(raised.exception))
        self.assertIsNone(client.notes)

    def test_an_authorization_error_is_raised_at_once(self):
        error = urllib.error.HTTPError("https://api", 403, "Forbidden", {}, None)
        client = FakeClient([error])
        with self.assertRaises(urllib.error.HTTPError):
            notes.publish_build_notes(client, self.args(wait_minutes=25), "text")


class AppStoreConnectTests(unittest.TestCase):
    def test_a_der_signature_becomes_64_raw_bytes(self):
        r, s = b"\x00" + b"\x81" * 32, b"\x01" * 20
        der = bytes([0x30, 4 + len(r) + len(s), 0x02, len(r)]) + r + bytes([0x02, len(s)]) + s
        raw = appstoreconnect.der_to_raw(der)
        self.assertEqual(raw, b"\x81" * 32 + b"\x00" * 12 + b"\x01" * 20)
        with self.assertRaises(ValueError):
            appstoreconnect.der_to_raw(b"\x31\x00")

    def test_the_token_is_an_es256_jwt_for_the_key(self):
        with tempfile.TemporaryDirectory() as directory:
            key = pathlib.Path(directory) / "AuthKey.p8"
            subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                            "-out", str(key)], check=True, capture_output=True)
            token = appstoreconnect.token("AB12CD34EF", "issuer", str(key))
        header, claims, signature = token.split(".")

        def decode(part):
            return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
        self.assertEqual(decode(header), {"alg": "ES256", "kid": "AB12CD34EF", "typ": "JWT"})
        self.assertEqual(decode(claims)["aud"], "appstoreconnect-v1")
        self.assertEqual(decode(claims)["iss"], "issuer")
        self.assertEqual(len(base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))), 64)

    def test_the_key_file_is_private_and_removed(self):
        environment = {"APP_STORE_CONNECT_PRIVATE_KEY": "key text", "APP_STORE_CONNECT_KEY_ID": "AB12CD34EF",
                       "APP_STORE_CONNECT_ISSUER_ID": "issuer"}
        with mock.patch.dict(os.environ, environment):
            with appstoreconnect.client_from_environment() as client:
                path = pathlib.Path(client.key_path)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                self.assertEqual(path.read_text(), "key text")
        self.assertFalse(path.exists())

    def test_the_app_is_looked_up_by_the_pantrified_bundle_id(self):
        self.assertEqual(appstoreconnect.BUNDLE_ID, "com.thisjustin816.Pantrified")


if __name__ == "__main__":
    unittest.main()
