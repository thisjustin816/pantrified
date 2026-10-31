#!/usr/bin/env python3
"""Checks that .github/workflows/testflight.yml keeps its guards, and that it, Scripts/upload-testflight.sh
and docs/testflight.md agree on the secrets and identifiers."""
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))
import appstoreconnect  # noqa: E402

WORKFLOW = (ROOT / ".github" / "workflows" / "testflight.yml").read_text()
SCRIPT = (ROOT / "Scripts" / "upload-testflight.sh").read_text()
DOC = (ROOT / "docs" / "testflight.md").read_text()
SECRETS = {
    "APPLE_DISTRIBUTION_PRIVATE_KEY", "APPLE_DISTRIBUTION_CERTIFICATE_BASE64", "APPLE_PROVISIONING_PROFILE_BASE64",
    "APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID", "APP_STORE_CONNECT_PRIVATE_KEY",
}


def jobs():
    body = WORKFLOW.split("\njobs:\n", 1)[1]
    parts = re.split(r"(?m)^  ([A-Za-z0-9_-]+):\n", body)
    return {parts[index]: parts[index + 1] for index in range(1, len(parts), 2)}


def steps(job):
    return re.split(r"\n      - ", job)[1:]


def step(job, name):
    found = [text for text in steps(job) if f"name: {name}\n" in text]
    assert len(found) == 1, name
    return found[0]


def run_blocks(text):
    blocks, lines = [], text.splitlines()
    for index, line in enumerate(lines):
        match = re.match(r"^(\s*)(?:- )?run:\s*(.*)$", line)
        if not match:
            continue
        if match.group(2) not in ("|", ">", "|-", ">-"):
            blocks.append(match.group(2))
            continue
        indent = len(match.group(1))
        body = []
        for following in lines[index + 1:]:
            if following.strip() and len(following) - len(following.lstrip()) <= indent:
                break
            body.append(following)
        blocks.append("\n".join(body))
    return blocks


class TriggerTests(unittest.TestCase):
    def test_it_runs_by_hand_or_after_the_ios_build_on_main(self):
        on_block = re.search(r"(?ms)^on:\n(.*?)^\S", WORKFLOW).group(1)
        self.assertEqual(re.findall(r"(?m)^  (\w+):", on_block), ["workflow_dispatch", "workflow_run"])
        self.assertIn("    workflows: [iOS build]\n    types: [completed]\n    branches: [main]\n", on_block)
        self.assertRegex((ROOT / ".github" / "workflows" / "ios-build.yml").read_text(), r"(?m)^name: iOS build$")
        self.assertRegex((ROOT / ".github" / "workflows" / "ci.yml").read_text(), r"(?m)^name: CI$")
        for forbidden in ("pull_request", "push:", "schedule:", "workflow_call", "repository_dispatch"):
            self.assertNotIn(forbidden, on_block)

    def test_the_upload_job_accepts_only_branches_and_pushes_to_this_repositorys_main(self):
        condition = re.search(r"(?ms)^    if: >-\n(.*?)^    runs-on:", jobs()["upload"]).group(1)
        words = " ".join(condition.split())
        for guard in ("(github.event_name == 'workflow_dispatch' && github.ref_type == 'branch')",
                      "github.event.workflow_run.conclusion == 'success'",
                      "github.event.workflow_run.event == 'push'",
                      "github.event.workflow_run.head_branch == 'main'",
                      "github.event.workflow_run.head_repository.full_name == github.repository"):
            self.assertIn(guard, words)
        self.assertEqual(words.count("||"), 1, "a guard is joined by || instead of &&")
        self.assertEqual(words.count("&&"), 5)

    def test_an_automatic_upload_waits_for_ci_on_the_same_commit(self):
        upload = jobs()["upload"]
        wait = step(upload, "Wait for CI on the commit")
        self.assertIn("if: github.event_name == 'workflow_run'", wait)
        self.assertIn("actions/workflows/ci.yml/runs?head_sha=$SHA&event=push", wait)
        self.assertIn("success) exit 0 ;;", wait)
        self.assertIn("*) echo \"::error::CI finished", wait)
        self.assertLess(upload.index("Wait for CI on the commit"), upload.index("Sign, archive and upload"))

    def test_a_docs_or_workflow_only_push_is_skipped(self):
        upload = jobs()["upload"]
        for name in ("Install XcodeGen", "Generate the Xcode project", "Sign, archive and upload"):
            self.assertIn("if: github.event_name != 'workflow_run' || steps.notes.outputs.app_changed == 'true'",
                          step(upload, name))

    def test_automatic_uploads_are_release_builds_that_upload(self):
        upload = jobs()["upload"]
        self.assertIn("TESTFLIGHT_VARIANT: ${{ github.event_name == 'workflow_dispatch' && inputs.variant || 'release' }}",
                      upload)
        self.assertIn("TESTFLIGHT_UPLOAD: ${{ github.event_name != 'workflow_dispatch' || inputs.upload }}", upload)


class SecretTests(unittest.TestCase):
    def test_the_workflow_script_and_docs_name_the_same_six_secrets(self):
        self.assertEqual(set(re.findall(r"secrets\.([A-Za-z0-9_]+)", WORKFLOW)), SECRETS)
        required = re.search(r"(?s)required=\((.*?)\)", SCRIPT).group(1).split()
        self.assertTrue(SECRETS <= set(required))
        for name in SECRETS:
            self.assertIn(f"| `{name}` |", DOC)

    def test_every_use_of_secrets_is_one_named_secret_under_its_own_name(self):
        allowed = {f"{name}: ${{{{ secrets.{name} }}}}" for name in SECRETS}
        for line in WORKFLOW.splitlines():
            if "secrets" in line and not line.strip().startswith("#"):
                self.assertIn(line.strip(), allowed, line)

    def test_only_the_signing_and_notes_steps_receive_secrets(self):
        holders = [text.split("\n", 1)[0] for job in jobs().values() for text in steps(job) if "secrets." in text]
        self.assertEqual(holders, ["name: Sign, archive and upload", "name: Set What to Test"])
        self.assertNotIn("secrets.", jobs()["tag"])

    def test_xcodegen_is_the_only_tool_installed_and_runs_before_the_secrets(self):
        upload = jobs()["upload"]
        first_secret = min(upload.index(f"secrets.{name}") for name in SECRETS)
        self.assertLess(upload.index("brew install xcodegen"), first_secret)
        self.assertLess(upload.index("make generate"), first_secret)
        installs = [line.strip() for line in upload.splitlines()
                    if re.search(r"\b(brew|pip3?|npm|gem|curl|wget|port)\b", line) and not line.strip().startswith("#")]
        self.assertEqual(installs, ["run: brew install xcodegen"])


class HardeningTests(unittest.TestCase):
    def test_run_scripts_hold_no_expressions(self):
        blocks = run_blocks(WORKFLOW)
        self.assertGreater(len(blocks), 5)
        for block in blocks:
            self.assertNotIn("${{", block)

    def test_actions_are_pinned_and_permissions_are_minimal(self):
        for action in re.findall(r"uses:\s*(\S+)", WORKFLOW):
            self.assertRegex(action, r"^[\w.-]+/[\w.-]+@[0-9a-f]{40}$")
        self.assertRegex(WORKFLOW, r"(?m)^permissions:\n  contents: read\n")
        self.assertIn("    permissions:\n      contents: read\n      # Reads the CI workflow's result on the same commit.\n"
                      "      actions: read\n", jobs()["upload"])
        self.assertIn("    permissions:\n      contents: write\n", jobs()["tag"])
        self.assertIn("persist-credentials: false", WORKFLOW)
        self.assertNotIn("pull_request_target", WORKFLOW)

    def test_runs_never_overlap(self):
        self.assertRegex(WORKFLOW, r"(?m)^concurrency:\n  group: testflight\n  cancel-in-progress: false\n")

    def test_only_main_uploads_are_tagged(self):
        self.assertIn("if: needs.upload.outputs.build != '' && needs.upload.outputs.branch == 'main'", jobs()["tag"])


class IdentifierTests(unittest.TestCase):
    def test_the_bundle_id_agrees_everywhere(self):
        script_id = re.search(r"(?m)^readonly BUNDLE_ID=(\S+)$", SCRIPT).group(1)
        project = (ROOT / "project.yml").read_text()
        project_id = re.search(r"PRODUCT_BUNDLE_IDENTIFIER: (\S+)\$\(BUNDLE_ID_SUFFIX\)", project).group(1)
        self.assertEqual({script_id, appstoreconnect.BUNDLE_ID, project_id}, {"com.thisjustin816.Pantrified"})
        self.assertIn(f"`{script_id}`", DOC)

    def test_the_docs_name_the_scripts_team_and_profile(self):
        for name in ("TEAM_ID", "PROFILE_UUID"):
            value = re.search(rf"(?m)^readonly {name}=(\S+)$", SCRIPT).group(1)
            self.assertIn(f"`{value}`", DOC)
        self.assertIn("30 October 2027", DOC)


if __name__ == "__main__":
    unittest.main()
