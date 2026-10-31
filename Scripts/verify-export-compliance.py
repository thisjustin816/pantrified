#!/usr/bin/env python3
"""Checks that the app declares it uses no non-exempt encryption and, optionally, that a built app does.

Usage: verify-export-compliance.py PROJECT_YML [APP_BUNDLE]

The owner's answer to App Store Connect's export-compliance question is that the app uses only the
encryption the operating system provides, so the app target sets
INFOPLIST_KEY_ITSAppUsesNonExemptEncryption to NO (docs/testflight-readiness.md). A change to that
answer is the owner's decision, so this check fails when the setting is missing or holds anything else.
With an app bundle, the generated Info.plist must carry ITSAppUsesNonExemptEncryption as false.
"""
import argparse
import pathlib
import plistlib
import re
import sys

TARGET = "Pantrified"
SETTING = "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption"
PLIST_KEY = "ITSAppUsesNonExemptEncryption"
ACCEPTED = {"NO", '"NO"', "'NO'"}


def _target_block(lines):
    """Returns the lines of the app target under the top-level targets key."""
    in_targets = False
    block = None
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            if block is not None:
                block.append(line)
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            if block is not None:
                break
            in_targets = line.rstrip() == "targets:"
            continue
        if in_targets and indent == 2:
            if block is not None:
                break
            if line.strip() == f"{TARGET}:":
                block = []
            continue
        if block is not None:
            block.append(line)
    return block


def check_project(text):
    block = _target_block(text.splitlines())
    if block is None:
        return [f"project.yml has no {TARGET} target"]
    pattern = re.compile(rf"^\s+{SETTING}:\s*(\S+)\s*(?:#.*)?$")
    values = [match.group(1) for match in map(pattern.match, block) if match]
    if not values:
        return [f"the {TARGET} target does not set {SETTING}"]
    if len(values) > 1:
        return [f"the {TARGET} target sets {SETTING} {len(values)} times"]
    if values[0] not in ACCEPTED:
        return [f"the {TARGET} target sets {SETTING} to {values[0]}, not NO; that answer is the owner's"]
    return []


def check_bundle(app):
    path = pathlib.Path(app) / "Info.plist"
    try:
        with open(path, "rb") as handle:
            info = plistlib.load(handle)
    except Exception as error:
        return [f"cannot read {path}: {error}"]
    if not isinstance(info, dict) or PLIST_KEY not in info:
        return [f"{path} has no {PLIST_KEY}"]
    if info[PLIST_KEY] is not False:
        return [f"{path} sets {PLIST_KEY} to {info[PLIST_KEY]!r}, not false"]
    return []


def check(project, app=None):
    try:
        text = pathlib.Path(project).read_text()
    except OSError as error:
        return [f"cannot read {project}: {error}"]
    errors = check_project(text)
    if app is not None:
        errors += check_bundle(app)
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("project")
    parser.add_argument("app", nargs="?")
    arguments = parser.parse_args(argv)
    errors = check(arguments.project, arguments.app)
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if not errors:
        print(f"{arguments.app or arguments.project}: declares no non-exempt encryption")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
