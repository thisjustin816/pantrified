#!/usr/bin/env python3
"""Checks that the privacy manifest declares exactly the required-reason API categories the code uses.

Usage: verify-required-reason-apis.py MANIFEST SOURCE_DIR [SOURCE_DIR ...]

Apple requires an app to declare, with an approved reason, each category of "required reason" API its
own code calls. This scans Swift sources for the symbols Apple lists per category and fails when a
category is used but not declared, declared but not used, or declared without a reason. It reads only
code: comments and string literals are ignored. It cannot see what a binary dependency calls, so the
archived app's privacy report is still the final check before a release.
"""
import argparse
import pathlib
import plistlib
import re
import sys
from collections import namedtuple

Result = namedtuple("Result", "used errors")

CATEGORY_PATTERNS = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        r"\bcreationDate\b|\bmodificationDate\b|\bfileModificationDate\b|\bfileCreationDate\b"
        r"|\bcontentModificationDateKey\b|\bcreationDateKey\b|\bcontentAccessDateKey\b"
        r"|\bNSFileCreationDate\b|\bNSFileModificationDate\b|\battributesOfItem\b"
        r"|(?<![A-Za-z0-9_.])[fl]?stat\(|\bfstatat\(|\bgetattrlist(?:at|bulk)?\(|\bfgetattrlist\("
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": r"\bsystemUptime\b|\bmach_absolute_time\b",
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        r"\bvolumeAvailableCapacity\w*Key\b|\bvolumeTotalCapacityKey\b|\bsystemFreeSize\b|\bsystemSize\b"
        r"|(?<![A-Za-z0-9_.])f?statv?fs\("
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": r"\bactiveInputModes\b",
    "NSPrivacyAccessedAPICategoryUserDefaults": r"\bUserDefaults\b|\bNSUserDefaults\b|@AppStorage\b",
}
COMPILED = {category: re.compile(pattern) for category, pattern in CATEGORY_PATTERNS.items()}


def _blank(match):
    """Replaces text with spaces but keeps its line breaks, so line numbers stay true."""
    return re.sub(r"[^\n]", " ", match.group(0))


def strip_comments_and_strings(source):
    source = re.sub(r'"""(?:.|\n)*?"""', _blank, source)
    source = re.sub(r'"(?:\\.|[^"\\\n])*"', _blank, source)
    source = re.sub(r"/\*(?:.|\n)*?\*/", _blank, source)
    return re.sub(r"//[^\n]*", _blank, source)


def scan(roots):
    used = {}
    for root in roots:
        for path in sorted(pathlib.Path(root).rglob("*.swift")):
            text = strip_comments_and_strings(path.read_text(encoding="utf-8", errors="replace"))
            for category, regex in COMPILED.items():
                for match in regex.finditer(text):
                    line = text.count("\n", 0, match.start()) + 1
                    used.setdefault(category, []).append((str(path), line))
    return used


def check(manifest_path, roots):
    try:
        manifest = plistlib.loads(pathlib.Path(manifest_path).read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        return Result({}, [f"cannot read the manifest {manifest_path}: {error}"])

    used = scan(roots)
    declared = {}
    errors = []
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        category = entry.get("NSPrivacyAccessedAPIType")
        declared[category] = entry.get("NSPrivacyAccessedAPITypeReasons") or []

    for category, reasons in declared.items():
        if category not in COMPILED:
            errors.append(f"{category} is an unknown category")
        elif not reasons:
            errors.append(f"{category} is declared with no reason")
        if category in COMPILED and category not in used:
            errors.append(f"{category} is declared but not used by any source")
    for category, uses in used.items():
        if category not in declared:
            file, line = uses[0]
            errors.append(f"{category} is used ({file}:{line}) but not declared in the manifest")
    return Result(used, errors)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("sources", nargs="+", type=pathlib.Path)
    args = parser.parse_args(argv)
    result = check(args.manifest, args.sources)
    for error in result.errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if result.errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
