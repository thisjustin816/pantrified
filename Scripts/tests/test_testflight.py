#!/usr/bin/env python3
"""Tests for Scripts/testflight.py, and checks that the TestFlight workflow and its docs agree with it."""
import base64
import contextlib
import datetime
import importlib.util
import io
import json
import os
import pathlib
import plistlib
import re
import stat
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
SCRIPT = ROOT / "Scripts" / "testflight.py"
spec = importlib.util.spec_from_file_location("testflight", SCRIPT)
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)

CONFIG = tf.load_config()
WORKFLOW = (ROOT / ".github" / "workflows" / "testflight.yml").read_text()
NOW = datetime.datetime(2026, 11, 1, tzinfo=datetime.timezone.utc)
DASHES = "-" * 5


def pem(kind, body="TESTKEYBODYMARKER0123456789"):
    return f"{DASHES}BEGIN {kind}{DASHES}\n{body}\n{DASHES}END {kind}{DASHES}\n"


CERTIFICATE_DER = b"\x30\x82\x05\x00" + bytes(range(100)) + b"CERTMARKER"
OTHER_CERTIFICATE_DER = b"\x30\x82\x05\x00" + bytes(range(100, 200)) + b"OTHERCERT"


def profile_plist(**changes):
    profile = {
        "UUID": CONFIG["profile_uuid"].upper(),
        "Name": CONFIG["profile_name"],
        "TeamIdentifier": [CONFIG["team_id"]],
        "ExpirationDate": datetime.datetime(2027, 10, 30, 12, 0, 0),
        "DeveloperCertificates": [CERTIFICATE_DER],
        "Entitlements": {
            "application-identifier": f"{CONFIG['team_id']}.{CONFIG['bundle_id']}",
            "com.apple.developer.team-identifier": CONFIG["team_id"],
            "get-task-allow": False,
            "beta-reports-active": True,
            "aps-environment": "production",
        },
    }
    for key, value in changes.items():
        if value is None:
            profile.pop(key, None)
        else:
            profile[key] = value
    return profile


def profile_bytes(profile=None):
    # A provisioning profile is a CMS envelope with the property list inside it in the clear.
    return b"\x30\x80\x06\x09CMSHEADER" + plistlib.dumps(profile or profile_plist()) + b"\x00CMSTRAILER"


def environ(**changes):
    values = {
        "GITHUB_REF": "refs/heads/main",
        "VARIANT": "release",
        "UPLOAD": "true",
        "APPLE_DISTRIBUTION_CERTIFICATE_BASE64": base64.encodebytes(CERTIFICATE_DER).decode(),
        "APPLE_DISTRIBUTION_PRIVATE_KEY": pem("PRIVATE KEY", "SIGNINGKEYMARKER"),
        "APPLE_PROVISIONING_PROFILE_BASE64": base64.b64encode(profile_bytes()).decode(),
        "APP_STORE_CONNECT_PRIVATE_KEY": pem("PRIVATE KEY", "APIKEYMARKER"),
        "APP_STORE_CONNECT_KEY_ID": "AB12CD34EF",
        "APP_STORE_CONNECT_ISSUER_ID": "69a6de70-03db-47e3-e053-5b8c7c11a4d1",
    }
    for key, value in changes.items():
        if value is None:
            values.pop(key, None)
        else:
            values[key] = value
    return values


def run_main(argv, env):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = tf.main(argv, env)
    return status, out.getvalue() + err.getvalue()


class CheckTests(unittest.TestCase):
    def check(self, **changes):
        return tf.check(environ(**changes), CONFIG, NOW)

    def test_a_complete_run_on_main_passes(self):
        self.assertEqual(self.check(), [])

    def test_the_names_in_the_config_are_the_ones_the_script_reads(self):
        self.assertEqual(set(CONFIG["required_secrets"]), {
            tf.CERTIFICATE, tf.SIGNING_KEY, tf.PROFILE, tf.API_KEY, tf.API_KEY_ID, tf.API_ISSUER_ID})

    def test_each_missing_or_blank_secret_is_named_alone(self):
        for name in CONFIG["required_secrets"]:
            for value in (None, "", "  \n"):
                with self.subTest(name=name, value=value):
                    self.assertEqual(self.check(**{name: value}), [f"{name} is not set or is empty"])

    def test_every_missing_secret_is_named(self):
        problems = tf.check({"GITHUB_REF": "refs/heads/main", "VARIANT": "release", "UPLOAD": "false"}, CONFIG, NOW)
        self.assertEqual(problems, [f"{name} is not set or is empty" for name in CONFIG["required_secrets"]])

    def test_only_main_is_accepted(self):
        for ref in ("refs/heads/feature/testflight-upload", "refs/tags/main", "refs/heads/main2",
                    "refs/pull/1/merge", "", None):
            with self.subTest(ref=ref):
                self.assertEqual(self.check(GITHUB_REF=ref),
                                 ["TestFlight builds run only from main; dispatch the workflow on main"])

    def test_inputs_are_validated(self):
        for variant in ("Release", "debug", "", None, "release; rm -rf /"):
            with self.subTest(variant=variant):
                self.assertEqual(self.check(VARIANT=variant), ["the variant input must be release or evaluation"])
        for upload in ("yes", "True", "", None):
            with self.subTest(upload=upload):
                self.assertEqual(self.check(UPLOAD=upload), ["the upload input must be true or false"])
        self.assertEqual(self.check(VARIANT="evaluation", UPLOAD="false"), [])

    def assert_one_problem(self, expected, **changes):
        problems = self.check(**changes)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn(expected, problems[0])

    def test_the_certificate_must_be_base64_der(self):
        self.assert_one_problem("APPLE_DISTRIBUTION_CERTIFICATE_BASE64 is not base64",
                                APPLE_DISTRIBUTION_CERTIFICATE_BASE64="not*base64!")
        self.assert_one_problem("does not decode to a DER certificate",
                                APPLE_DISTRIBUTION_CERTIFICATE_BASE64=base64.b64encode(b"x" * 100).decode())

    def test_the_signing_key_must_be_one_unencrypted_private_key(self):
        for kind in ("RSA PRIVATE KEY", "EC PRIVATE KEY"):
            with self.subTest(kind=kind):
                self.assertEqual(self.check(APPLE_DISTRIBUTION_PRIVATE_KEY=pem(kind)), [])
        self.assert_one_problem("is an encrypted key", APPLE_DISTRIBUTION_PRIVATE_KEY=pem("ENCRYPTED PRIVATE KEY"))
        self.assert_one_problem("is not the PEM text of one private key", APPLE_DISTRIBUTION_PRIVATE_KEY=pem("CERTIFICATE"))
        self.assert_one_problem("is not the PEM text of one private key", APPLE_DISTRIBUTION_PRIVATE_KEY="MIIEvQIBADANBg")
        self.assert_one_problem("is not the PEM text of one private key",
                                APPLE_DISTRIBUTION_PRIVATE_KEY=pem("PRIVATE KEY") + pem("PRIVATE KEY"))
        self.assert_one_problem("has no matching END line",
                                APPLE_DISTRIBUTION_PRIVATE_KEY=pem("PRIVATE KEY").split(f"{DASHES}END")[0])

    def test_the_profile_must_be_base64_with_a_property_list(self):
        self.assert_one_problem("APPLE_PROVISIONING_PROFILE_BASE64 is not base64",
                                APPLE_PROVISIONING_PROFILE_BASE64="%%%")
        self.assert_one_problem("does not contain a provisioning profile property list",
                                APPLE_PROVISIONING_PROFILE_BASE64=base64.b64encode(b"\x30\x80 nothing").decode())
        self.assert_one_problem("cannot be read",
                                APPLE_PROVISIONING_PROFILE_BASE64=base64.b64encode(b"<?xml <plist>junk</plist>").decode())

    def profile_problem(self, expected, **changes):
        encoded = base64.b64encode(profile_bytes(profile_plist(**changes))).decode()
        self.assert_one_problem(expected, APPLE_PROVISIONING_PROFILE_BASE64=encoded)

    def entitlements(self, **changes):
        entitlements = dict(profile_plist()["Entitlements"])
        for key, value in changes.items():
            if value is None:
                entitlements.pop(key)
            else:
                entitlements[key] = value
        return entitlements

    def test_the_profile_must_match_the_config(self):
        self.profile_problem("is not the profile whose UUID", UUID="00000000-0000-0000-0000-000000000000")
        self.profile_problem("is not named 'Pantrified App Store'", Name="Pantrified Development")
        self.profile_problem("is not for team S2TFTKR4CS", TeamIdentifier=["ABCDE12345"])
        self.profile_problem("is not for the bundle identifier",
                             Entitlements=self.entitlements(**{"application-identifier": "S2TFTKR4CS.com.example"}))

    def test_the_profile_must_be_an_app_store_profile(self):
        self.profile_problem("lists devices", ProvisionedDevices=["00008110-000A"])
        self.profile_problem("lists devices", ProvisionsAllDevices=True)
        self.profile_problem("allows a debugger to attach", Entitlements=self.entitlements(**{"get-task-allow": True}))
        self.profile_problem("allows a debugger to attach", Entitlements=self.entitlements(**{"get-task-allow": None}))
        self.profile_problem("does not allow TestFlight", Entitlements=self.entitlements(**{"beta-reports-active": None}))

    def test_the_profile_must_be_current_and_hold_the_certificate(self):
        self.profile_problem("expired on 2026-10-30", ExpirationDate=datetime.datetime(2026, 10, 30))
        self.profile_problem("has no expiration date", ExpirationDate=None)
        self.profile_problem("does not include the certificate", DeveloperCertificates=[OTHER_CERTIFICATE_DER])

    def test_a_profile_close_to_expiry_warns(self):
        soon = profile_plist(ExpirationDate=datetime.datetime(2026, 11, 20))
        self.assertIn("2026-11-20", tf.profile_expiry_warning(soon, NOW))
        self.assertIsNone(tf.profile_expiry_warning(profile_plist(), NOW))

    def test_the_app_store_connect_key_and_ids_are_checked(self):
        self.assert_one_problem("APP_STORE_CONNECT_PRIVATE_KEY is not the PEM text",
                                APP_STORE_CONNECT_PRIVATE_KEY=pem("EC PRIVATE KEY"))
        for key_id in ("ab12cd34ef", "AB12CD34E", "AB12CD34EFG", "../../AB12"):
            with self.subTest(key_id=key_id):
                self.assert_one_problem("APP_STORE_CONNECT_KEY_ID is not a 10-character key ID",
                                        APP_STORE_CONNECT_KEY_ID=key_id)
        self.assert_one_problem("APP_STORE_CONNECT_ISSUER_ID is not a UUID", APP_STORE_CONNECT_ISSUER_ID="issuer")


class NoValueIsPrintedTests(unittest.TestCase):
    MARKER = "S3CR3TVALUEMARKER"

    def secret_values(self, env):
        return [value.strip() for name, value in env.items() if name in CONFIG["required_secrets"] and value.strip()]

    def assert_quiet(self, env, argv=("check",)):
        status, output = run_main(list(argv), env)
        for value in self.secret_values(env):
            for piece in [value] + [line for line in value.splitlines() if len(line) > 6]:
                self.assertNotIn(piece, output)
        self.assertNotIn(self.MARKER, output)
        return status, output

    def test_valid_secrets_are_not_printed(self):
        status, output = self.assert_quiet(environ())
        self.assertEqual(status, 0, output)

    def test_invalid_secrets_are_named_but_not_printed(self):
        env = {name: f"{self.MARKER}-{name}" for name in CONFIG["required_secrets"]}
        env.update(GITHUB_REF="refs/heads/main", VARIANT="release", UPLOAD="true")
        status, output = self.assert_quiet(env)
        self.assertEqual(status, 1)
        for name in CONFIG["required_secrets"]:
            self.assertIn(name, output)

    def test_an_unexpected_error_prints_only_its_type(self):
        with mock.patch.object(tf, "check", side_effect=ValueError(self.MARKER)):
            status, output = self.assert_quiet(environ())
        self.assertEqual(status, 1)
        self.assertIn("unexpected ValueError", output)

    def test_prepare_and_write_api_key_print_no_value(self):
        with tempfile.TemporaryDirectory() as directory:
            env = environ()
            with mock.patch.object(pathlib.Path, "home", return_value=pathlib.Path(directory) / "home"):
                status, _ = self.assert_quiet(env, ("prepare", f"{directory}/signing"))
                self.assertEqual(status, 0)
                status, _ = self.assert_quiet(env, ("write-api-key", f"{directory}/signing"))
                self.assertEqual(status, 0)


class BuildInfoTests(unittest.TestCase):
    PROJECT = 'settings:\n  base:\n    CURRENT_PROJECT_VERSION: 1\n    MARKETING_VERSION: "0.1"\n'

    def info(self, variant="release", run_number="12", run_attempt="1", project=PROJECT):
        env = {"VARIANT": variant, "GITHUB_RUN_NUMBER": run_number, "GITHUB_RUN_ATTEMPT": run_attempt}
        return tf.build_info(env, CONFIG, project)

    def test_the_repository_project_has_one_marketing_version(self):
        self.assertRegex(tf.marketing_version((ROOT / "project.yml").read_text()), r"^[0-9]+(\.[0-9]+){0,2}$")

    def test_the_marketing_version_must_be_set_once_and_numeric(self):
        for text in ("", 'MARKETING_VERSION: "0.1"\nMARKETING_VERSION: "0.2"\n', "MARKETING_VERSION: one\n",
                     "MARKETING_VERSION: 1.2.3.4\n"):
            with self.subTest(text=text), self.assertRaises(tf.Failure):
                tf.marketing_version(text)
        self.assertEqual(tf.marketing_version("    MARKETING_VERSION: 2.10.1 # next\n"), "2.10.1")

    def test_the_build_number_is_the_run_number_and_attempt(self):
        self.assertEqual(self.info()["build_number"], "12.1")
        self.assertEqual(self.info(run_attempt="3")["build_number"], "12.3")

    def test_build_numbers_increase_across_runs_and_attempts(self):
        def key(number):
            return tuple(int(part) for part in number.split("."))
        numbers = [tf.build_number(str(run), str(attempt)) for run in (9, 10, 11) for attempt in (1, 2)]
        self.assertEqual(sorted(numbers, key=key), numbers)
        self.assertEqual(len(set(numbers)), len(numbers))

    def test_the_run_number_must_be_a_positive_whole_number(self):
        for run_number, run_attempt in (("0", "1"), ("12", ""), ("1.2", "1"), (None, "1"), ("12", "-1")):
            with self.subTest(run_number=run_number, run_attempt=run_attempt), self.assertRaises(tf.Failure):
                self.info(run_number=run_number, run_attempt=run_attempt)

    def test_the_variants_are_told_apart(self):
        release, evaluation = self.info("release"), self.info("evaluation")
        self.assertEqual(release["artifact_name"], "testflight-release-0.1-build-12.1")
        self.assertEqual(evaluation["artifact_name"], "testflight-evaluation-0.1-build-12.1")
        self.assertEqual((release["archive_name"], evaluation["archive_name"]),
                         ("Pantrified-Release", "Pantrified-Evaluation"))
        self.assertEqual((release["evaluation_tab"], evaluation["evaluation_tab"]), ("absent", "present"))
        self.assertEqual((release["internal_only"], evaluation["internal_only"]), ("false", "true"))

    def test_an_unknown_variant_fails(self):
        with self.assertRaises(tf.Failure):
            self.info("debug")

    def test_the_command_writes_the_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "output"
            env = {"VARIANT": "evaluation", "GITHUB_RUN_NUMBER": "7", "GITHUB_RUN_ATTEMPT": "2",
                   "GITHUB_OUTPUT": str(output)}
            status, printed = run_main(["build-info"], env)
            self.assertEqual(status, 0, printed)
            lines = output.read_text().splitlines()
        self.assertIn("variant=evaluation", lines)
        self.assertIn("build_number=7.2", lines)
        self.assertIn("Variant: Evaluation", printed)


class ExportOptionsTests(unittest.TestCase):
    def test_the_options_sign_manually_for_app_store_connect(self):
        options = tf.export_options("release", CONFIG)
        self.assertEqual(options["method"], "app-store-connect")
        self.assertEqual(options["destination"], "export")
        self.assertEqual(options["signingStyle"], "manual")
        self.assertEqual(options["teamID"], CONFIG["team_id"])
        self.assertEqual(options["signingCertificate"], "Apple Distribution")
        self.assertEqual(options["provisioningProfiles"], {CONFIG["bundle_id"]: CONFIG["profile_uuid"]})
        self.assertIs(options["manageAppVersionAndBuildNumber"], False)

    def test_only_the_evaluation_build_is_internal_only(self):
        self.assertIs(tf.export_options("release", CONFIG)["testFlightInternalTestingOnly"], False)
        self.assertIs(tf.export_options("evaluation", CONFIG)["testFlightInternalTestingOnly"], True)

    def test_an_unknown_variant_fails(self):
        with self.assertRaises(tf.Failure):
            tf.export_options("debug", CONFIG)

    def test_the_command_writes_a_property_list(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "ExportOptions.plist"
            status, _ = run_main(["export-options", str(path)], {"VARIANT": "evaluation"})
            self.assertEqual(status, 0)
            self.assertIs(plistlib.loads(path.read_bytes())["testFlightInternalTestingOnly"], True)


class XcconfigTests(unittest.TestCase):
    def test_the_settings_sign_the_app_target_manually(self):
        text = tf.xcconfig_text(CONFIG)
        self.assertIn("CODE_SIGN_STYLE = Manual", text)
        self.assertIn("DEVELOPMENT_TEAM = S2TFTKR4CS", text)
        self.assertIn("CODE_SIGN_IDENTITY = Apple Distribution", text)
        self.assertIn("PROVISIONING_PROFILE_SPECIFIER = Pantrified App Store", text)
        self.assertRegex(text, r"(?m)^BUNDLE_ID_SUFFIX =$")

    def test_an_existing_file_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "Signing.local.xcconfig"
            path.write_text("DEVELOPMENT_TEAM = MINE\n")
            status, output = run_main(["xcconfig", str(path)], {})
            self.assertEqual(status, 1)
            self.assertIn("already exists", output)
            self.assertEqual(path.read_text(), "DEVELOPMENT_TEAM = MINE\n")


class MaterialTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.base = pathlib.Path(self.directory.name)
        self.home = self.base / "home"
        self.signing = self.base / "signing"

    def tearDown(self):
        self.directory.cleanup()

    def prepare(self, env=None):
        return tf.prepare(self.signing, env or environ(), CONFIG, self.home, NOW)

    def profile_paths(self):
        name = f"{CONFIG['profile_uuid'].upper()}.mobileprovision"
        return [self.home / directory / name for directory in tf.PROFILE_DIRECTORIES]

    def mode(self, path):
        return stat.S_IMODE(os.stat(path).st_mode)

    def test_prepare_writes_private_files_and_installs_the_profile(self):
        self.prepare()
        self.assertEqual(self.mode(self.signing), 0o700)
        self.assertEqual((self.signing / "certificate.der").read_bytes(), CERTIFICATE_DER)
        self.assertIn("SIGNINGKEYMARKER", (self.signing / "private-key.pem").read_text())
        for name in ("certificate.der", "private-key.pem"):
            self.assertEqual(self.mode(self.signing / name), 0o600)
        for path in self.profile_paths():
            self.assertEqual(path.read_bytes(), profile_bytes())
            self.assertEqual(self.mode(path), 0o600)
        recorded = (self.signing / tf.INSTALLED_PROFILES).read_text().splitlines()
        self.assertEqual(recorded, [str(path) for path in self.profile_paths()])

    def test_prepare_refuses_bad_material_and_writes_nothing(self):
        with self.assertRaises(tf.Failure):
            self.prepare(environ(APPLE_DISTRIBUTION_PRIVATE_KEY=pem("CERTIFICATE")))
        self.assertFalse(self.signing.exists())
        self.assertFalse(self.home.exists())

    def test_prepare_refuses_a_leftover_directory(self):
        self.signing.mkdir()
        with self.assertRaises(tf.Failure):
            self.prepare()

    def test_an_identical_installed_profile_is_kept_and_not_recorded(self):
        existing = self.profile_paths()[0]
        existing.parent.mkdir(parents=True)
        existing.write_bytes(profile_bytes())
        self.prepare()
        recorded = (self.signing / tf.INSTALLED_PROFILES).read_text().splitlines()
        self.assertEqual(recorded, [str(self.profile_paths()[1])])
        tf.cleanup(self.signing)
        self.assertTrue(existing.exists())
        self.assertFalse(self.profile_paths()[1].exists())

    def test_a_different_profile_with_the_same_uuid_is_not_replaced(self):
        existing = self.profile_paths()[0]
        existing.parent.mkdir(parents=True)
        existing.write_bytes(b"other")
        with self.assertRaises(tf.Failure):
            self.prepare()
        self.assertEqual(existing.read_bytes(), b"other")

    def test_a_written_file_never_replaces_an_existing_one(self):
        path = self.base / "existing"
        path.write_bytes(b"keep")
        with self.assertRaises(FileExistsError):
            tf._write_private(path, b"new")
        self.assertEqual(path.read_bytes(), b"keep")

    def test_write_api_key_names_the_file_for_altool(self):
        self.prepare()
        keys = tf.write_api_key(self.signing, environ())
        path = keys / "AuthKey_AB12CD34EF.p8"
        self.assertIn("APIKEYMARKER", path.read_text())
        self.assertEqual(self.mode(keys), 0o700)
        self.assertEqual(self.mode(path), 0o600)

    def test_write_api_key_refuses_a_bad_key_id_and_a_missing_directory(self):
        self.prepare()
        with self.assertRaises(tf.Failure):
            tf.write_api_key(self.signing, environ(APP_STORE_CONNECT_KEY_ID="../../../x"))
        self.assertFalse((self.signing / "private_keys").exists())
        with self.assertRaises(tf.Failure):
            tf.write_api_key(self.base / "missing", environ())

    def test_cleanup_removes_what_the_run_wrote(self):
        self.prepare()
        tf.write_api_key(self.signing, environ())
        xcconfig = self.base / "Signing.local.xcconfig"
        xcconfig.write_text(tf.xcconfig_text(CONFIG))
        tf.cleanup(self.signing, xcconfig)
        self.assertFalse(self.signing.exists())
        self.assertFalse(xcconfig.exists())
        for path in self.profile_paths():
            self.assertFalse(path.exists())

    def test_cleanup_keeps_a_developers_xcconfig_and_tolerates_nothing_to_do(self):
        xcconfig = self.base / "Signing.local.xcconfig"
        xcconfig.write_text("DEVELOPMENT_TEAM = MINE\n")
        self.assertEqual(tf.cleanup(self.signing, xcconfig), [])
        self.assertTrue(xcconfig.exists())


class VerifyAppTests(unittest.TestCase):
    INFO = {"CFBundleIdentifier": CONFIG["bundle_id"], "CFBundleShortVersionString": "0.1", "CFBundleVersion": "12.1"}
    ENTITLEMENTS = {
        "application-identifier": f"{CONFIG['team_id']}.{CONFIG['bundle_id']}",
        "com.apple.developer.team-identifier": CONFIG["team_id"],
        "get-task-allow": False,
        "beta-reports-active": True,
    }
    CODESIGN = ("Executable=/tmp/Payload/Pantrified.app/Pantrified\nIdentifier=com.thisjustin816.Pantrified\n"
                "Authority=Apple Distribution: Owner (S2TFTKR4CS)\nAuthority=Apple Worldwide Developer Relations "
                "Certification Authority\nAuthority=Apple Root CA\nTeamIdentifier=S2TFTKR4CS\n")

    def verify(self, info=None, profile=b"default", entitlements=None, codesign=None):
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory) / "Pantrified.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps(info or self.INFO, fmt=plistlib.FMT_BINARY))
            if profile is not None:
                (app / "embedded.mobileprovision").write_bytes(profile_bytes() if profile == b"default" else profile)
            entitlements_path = codesign_path = None
            if entitlements is not None:
                entitlements_path = pathlib.Path(directory) / "entitlements.plist"
                entitlements_path.write_bytes(plistlib.dumps(entitlements))
            if codesign is not None:
                codesign_path = pathlib.Path(directory) / "codesign.txt"
                codesign_path.write_text(codesign)
            return tf.verify_app(app, CONFIG, "0.1", "12.1", entitlements_path, codesign_path)

    def test_a_correct_app_passes(self):
        self.assertEqual(self.verify(entitlements=self.ENTITLEMENTS, codesign=self.CODESIGN), [])

    def test_identifiers_and_versions_must_match(self):
        for key, value in (("CFBundleIdentifier", "com.thisjustin816.Pantrified.dev"),
                           ("CFBundleShortVersionString", "0.2"), ("CFBundleVersion", "1")):
            with self.subTest(key=key):
                problems = self.verify(info=dict(self.INFO, **{key: value}))
                self.assertEqual(len(problems), 1)
                self.assertIn(key, problems[0])

    def test_the_embedded_profile_must_be_the_configured_one(self):
        self.assertEqual(self.verify(profile=None), ["the app has no embedded provisioning profile"])
        other = profile_bytes(profile_plist(UUID="00000000-0000-0000-0000-000000000000"))
        self.assertIn("other than the one", self.verify(profile=other)[0])

    def test_the_signed_entitlements_must_be_for_distribution(self):
        cases = {
            "get-task-allow": (True, "get-task-allow"),
            "beta-reports-active": (None, "beta-reports-active"),
            "application-identifier": ("S2TFTKR4CS.com.example", "application-identifier"),
            "com.apple.developer.team-identifier": ("ABCDE12345", "team identifier"),
        }
        for key, (value, expected) in cases.items():
            with self.subTest(key=key):
                entitlements = dict(self.ENTITLEMENTS)
                if value is None:
                    entitlements.pop(key)
                else:
                    entitlements[key] = value
                problems = self.verify(entitlements=entitlements)
                self.assertEqual(len(problems), 1, problems)
                self.assertIn(expected, problems[0])

    def test_the_signature_must_be_a_distribution_signature_of_the_team(self):
        development = self.CODESIGN.replace("Apple Distribution", "Apple Development")
        self.assertEqual(self.verify(codesign=development),
                         ["the app is not signed with an Apple Distribution certificate"])
        self.assertEqual(self.verify(codesign=self.CODESIGN.replace("TeamIdentifier=S2TFTKR4CS", "TeamIdentifier=not set")),
                         ["the signature's team is not S2TFTKR4CS"])
        self.assertIn("not signed with", self.verify(codesign="Executable=x\n")[0])


class RecordTests(unittest.TestCase):
    def test_the_record_holds_the_build_and_no_secret(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = pathlib.Path(directory) / "summary.md"
            path = pathlib.Path(directory) / "record" / "build.json"
            env = environ(VARIANT="evaluation", INTERNAL_ONLY="true", MARKETING_VERSION="0.1", BUILD_NUMBER="12.1",
                          UPLOAD_OUTCOME="skipped",
                          GITHUB_SHA="abc123", GITHUB_RUN_ID="99", GITHUB_STEP_SUMMARY=str(summary))
            status, _ = run_main(["record", str(path)], env)
            self.assertEqual(status, 0)
            record = json.loads(path.read_text())
            text = path.read_text() + summary.read_text()
        self.assertEqual(record["variant"], "evaluation")
        self.assertEqual(record["internal_only"], "true")
        self.assertIn("| internal_only | true |", text)
        self.assertEqual(record["build_number"], "12.1")
        self.assertEqual(record["upload"], "skipped")
        for name in CONFIG["required_secrets"]:
            self.assertNotIn(environ()[name].strip(), text)


def run_blocks(text):
    """Returns the body of every run: key in a workflow."""
    blocks = []
    lines = text.splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^(\s*)(?:- )?run:\s*(.*)$", line)
        if not match:
            continue
        indent = len(match.group(1))
        if match.group(2) not in ("|", ">", "|-", ">-"):
            blocks.append(match.group(2))
            continue
        body = []
        for following in lines[index + 1:]:
            if following.strip() and len(following) - len(following.lstrip()) <= indent:
                break
            body.append(following)
        blocks.append("\n".join(body))
    return blocks


def steps(text):
    return re.split(r"\n      - ", text)


def jobs(text):
    """Returns each job's text by its ID, from the top-level jobs key to the end of the file."""
    body = text.split("\njobs:\n", 1)[1]
    parts = re.split(r"(?m)^  ([A-Za-z0-9_-]+):\n", body)
    return {parts[index]: parts[index + 1] for index in range(1, len(parts), 2)}


class WorkflowTests(unittest.TestCase):
    def test_it_runs_only_when_dispatched(self):
        on_block = re.search(r"(?ms)^on:\n(.*?)^\S", WORKFLOW).group(1)
        triggers = re.findall(r"(?m)^  (\w+):", on_block)
        self.assertEqual(triggers, ["workflow_dispatch"])
        for forbidden in ("pull_request", "pull_request_target", "push:", "schedule", "workflow_run"):
            self.assertNotIn(forbidden, WORKFLOW)

    def test_the_secrets_it_reads_are_the_required_ones(self):
        # Every mention of the secrets context, in an expression or not, must be one of the six
        # NAME: ${{ secrets.NAME }} lines; toJSON(secrets), secrets['X'] and secrets: inherit all fail.
        allowed = {f"{name}: ${{{{ secrets.{name} }}}}" for name in CONFIG["required_secrets"]}
        for line in WORKFLOW.splitlines():
            if re.search(r"secrets", line, re.I):
                self.assertIn(line.strip(), allowed, f"secrets used other than as a required secret: {line.strip()}")
        referenced = set(re.findall(r"secrets\.([A-Za-z0-9_]+)", WORKFLOW))
        self.assertEqual(referenced, set(CONFIG["required_secrets"]))
        self.assertNotIn("GITHUB_TOKEN", WORKFLOW)
        self.assertNotIn("github.token", WORKFLOW)

    def test_the_check_step_receives_every_secret(self):
        check = [step for step in steps(WORKFLOW) if "testflight.py check" in step]
        self.assertEqual(len(check), 1)
        for name in CONFIG["required_secrets"]:
            self.assertIn(f"{name}: ${{{{ secrets.{name} }}}}", check[0])

    def test_the_check_runs_before_anything_is_built(self):
        signing = jobs(WORKFLOW)["signed-build"]
        order = [signing.index(text) for text in ("testflight.py check", "testflight-project.py unpack",
                                                  "testflight.py prepare", "testflight-xcode.sh archive")]
        self.assertEqual(order, sorted(order))

    def test_xcodegen_runs_in_a_job_without_secrets_or_the_environment(self):
        all_jobs = jobs(WORKFLOW)
        self.assertEqual(list(all_jobs), ["main-only", "generate-project", "signed-build"])
        generate = all_jobs["generate-project"]
        self.assertIn("brew install xcodegen", generate)
        self.assertIn("testflight-project.py pack", generate)
        for job in ("main-only", "generate-project"):
            self.assertNotRegex(all_jobs[job], r"secrets|environment:", job)

    def test_the_signing_job_installs_no_third_party_tool(self):
        signing = jobs(WORKFLOW)["signed-build"]
        for tool in ("brew ", "xcodegen", "pip ", "pip3 ", "npm ", "gem ", "curl ", "wget ", "make generate"):
            self.assertNotIn(tool, signing)
        actions = re.findall(r"uses:\s*([\w.-]+/[\w.-]+)@", signing)
        self.assertEqual(actions, ["actions/checkout", "actions/upload-artifact"])
        self.assertIn("needs.generate-project.outputs.project }}", signing)
        self.assertIn("needs.generate-project.outputs.project_sha256 }}", signing)

    def test_the_only_variable_is_the_runner(self):
        self.assertEqual(set(re.findall(r"vars\.([A-Za-z0-9_]+)", WORKFLOW)), {"MACOS_RUNNER"})

    def test_run_scripts_hold_no_expressions(self):
        blocks = run_blocks(WORKFLOW)
        self.assertGreater(len(blocks), 10)
        for block in blocks:
            self.assertNotIn("${{", block)

    def test_actions_are_pinned_and_permissions_are_minimal(self):
        uses = re.findall(r"uses:\s*(\S+)", WORKFLOW)
        self.assertTrue(uses)
        for action in uses:
            self.assertRegex(action, r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$")
        self.assertRegex(WORKFLOW, r"(?m)^permissions:\n  contents: read\n")
        self.assertEqual(len(re.findall(r"(?m)^\s*permissions:", WORKFLOW)), 2)
        self.assertIn("permissions: {}", WORKFLOW)
        self.assertIn("persist-credentials: false", WORKFLOW)

    def test_the_signing_job_is_guarded_and_uses_the_environment(self):
        all_jobs = jobs(WORKFLOW)
        signing = all_jobs["signed-build"]
        self.assertRegex(signing, rf"(?m)^    environment: {CONFIG['environment']}$")
        self.assertRegex(signing, r"(?m)^    needs: \[main-only, generate-project\]$")
        self.assertRegex(signing, r"(?m)^    if: github\.ref == 'refs/heads/main'$")
        self.assertIn('if [ "$REF" != refs/heads/main ]', all_jobs["main-only"])
        self.assertRegex(all_jobs["generate-project"], r"(?m)^    needs: main-only$")

    def test_cleanup_always_runs_and_comes_before_the_artifact_upload(self):
        cleanup = [step for step in steps(WORKFLOW) if "testflight.py cleanup" in step]
        self.assertEqual(len(cleanup), 1)
        self.assertIn("if: always()", cleanup[0])
        self.assertIn("testflight-keychain.sh teardown", cleanup[0])
        self.assertLess(WORKFLOW.index("testflight.py cleanup"), WORKFLOW.index("actions/upload-artifact"))

    def test_the_api_key_is_only_in_the_check_and_the_step_that_writes_it(self):
        holders = [step for step in steps(WORKFLOW) if "secrets.APP_STORE_CONNECT_PRIVATE_KEY" in step]
        self.assertEqual(len(holders), 2)
        self.assertIn("testflight.py check", holders[0])
        self.assertIn("testflight.py write-api-key", holders[1])
        signing = [step for step in steps(WORKFLOW) if "secrets.APPLE_DISTRIBUTION_PRIVATE_KEY" in step]
        self.assertEqual(len(signing), 2)
        self.assertIn("testflight.py prepare", signing[1])

    def test_it_does_not_answer_export_compliance_or_change_signing_assets(self):
        self.assertNotIn("allowProvisioningUpdates", WORKFLOW)
        self.assertNotIn("allowProvisioningUpdates",
                         (ROOT / "Scripts" / "testflight-xcode.sh").read_text().replace("no command passes -allowProvisioningUpdates", ""))


class DocsTests(unittest.TestCase):
    def test_the_upload_doc_lists_every_setting(self):
        text = (ROOT / "docs" / "testflight-upload.md").read_text()
        for name in CONFIG["required_secrets"] + ["MACOS_RUNNER"]:
            self.assertIn(f"`{name}`", text)
        for key in ("environment", "team_id", "bundle_id", "app_apple_id", "profile_name", "profile_uuid"):
            self.assertIn(CONFIG[key], text)
        self.assertIn("30 October 2027", text)

    def test_the_other_docs_point_to_it(self):
        for name in ("ci.md", "testflight-readiness.md"):
            text = (ROOT / "docs" / name).read_text()
            self.assertIn("testflight-upload.md", text)
            self.assertIn("testflight.yml", text)


if __name__ == "__main__":
    unittest.main()
